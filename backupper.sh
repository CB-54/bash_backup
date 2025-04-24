#!/bin/bash
USAGE=$(cat <<EOF
Usage:
  $0 [options]

Create full and incremental (using hardlink) backups via rsync local-to-local and remote-to-local, dump SQL and archive backups.

Options:
	-S | --src {PATH} : Source path. It must be absolute path.
		You can set multiple source path using multiple --src | -S
	-D | --dst {PATH} : Destination path. It must be absolute path.
	-t | --timestamp : Use full timestamp (2024-01-01_00-30) instead date (2024-01-01)
	-R : Save absolute path in backup destenation instead relative path

	-s | --sql  : Enable SQL dump for all databases. Must be set correct login and password in users ~/.my.cnf file
	-z | --sqlzip : Save SQL dump into compressed .sql.gz instead of regular .sql

	-p | --psql : Enable PG SQL dump for all databases
	--pzip : Enable compressing for PG SQL dump
	--puser {username} : Set psql user. By default "postgres" is used
	--ppass {password} : Set psql password for password type auth
		Warning: /root/.pgpass file will be overrided if --ppass is used
	--pport {port} : Set custom TCP port for PGSQL server. By default 5432 is used
	--pauth {unix|pass} : Set authorize method for psql. By default "unix" is used
	--pdump {raw|bin} : Set file type and method for psql dump. By default "raw" is used
		raw - save dump in text file (like MySQL .sql files)
			Use [psql mydb < mydb.sql] to restore raw DB file
		bin - use PG SQL binary encoding to save into binary file with compression
			Use [pg_restore -d mydb mydb.dump] to restore bin DB file

	-l | --local : Use local-to-local backup instead remote-to-local
	-k | --ssh-key {PATH} : Path to SSH key for remote-to-local backup
	-p | --ssh-port {PORT} : Set SSH port for remote-to-local backup
	-u | --user {USER} : Set SSH user for remote-to-local backup
	-i | --ip {IP} : Set remote IPv4 server for remote-to-local backup
	-I | --io : Set I/O limit for rsync. In megabytes/sec. 

	-o | --owner {USERNAME} : Change ownership for created backups.
	-f | --full : Make full backup instead of an incremental backup
	-a | --archive : Archive backup copy into .tar
	--gz : Compress into .tar.gz instead .tar
	
	--force : Do not check if another copy of this program still working	
	--mount {MOUNT} : Set a mount point, label or device to set in on read-only after making backup.
		Example: D:/dev/sda or D:/dev/sdb1 or M:/backup or L:backup D stands for DEVICE, M stands for MOUNTPOINT, L stands for LABEL
	--notify : Send notification to backupmon.example.ua/backuplocal.php about start/end
	--hostname {HOSTNAME} : Set a custom hostname for --notify and --mail. By default using current server hostname

	--mail {MAIL} : Send email notification about backup
		Can set multiple mailbox, using : as separator. Ex: client@mail.ua:dev@gmail.com:dev2@gmail.com
	--mail-type {10|20|11|21} : Set mailing level
		10 - send notification only after backup was created and send error's
		20 - send notification about START and END backup creation and send error's
		11 - send notification only after backup was created and don't send error's
		21 - send notification about START and END backup creation and don't send error's
		By default used 10
	--mail-lang {UA|EN} : Set email notification language
		By default used UA langauge.

	-d | --delete-old {NUMBER}M|D : Delete backups older than N minutes/days. Ex: -d 120M or -d 14D
		M - minutes, D - days.
	-q | --quota {QUOTA} : Set maximum size of destenation directory in MegaBytes OR set block device ex: /dev/sda1, /dev/sda
		Old backups will be deleted to meet quota limits.
	--real-calc : Calculate real size for dst directory every time
		Instead used cached size, which is may be not accurate.
	--dry : Do not delete old backups or overquota backups

	-E | --exclude {PATH} : Add exclude directory/file to rsync and tar commands
	-e | --custom-exclude {PATH} : Set a text file with user exclude location list to rsync and tar

	-v | --verbose : Verbose mode
	-V | --extra-verbose : Use verbose mode for tar and rsync
	-h | --help : Show this help
EOF
)
function MAILERR {
	echo "	ERROR: $1"
	[[ $MAIL_TYPE == *1 ]] && return 0
	local ERR_TEXT=$(echo $1 | sed 's! !%20!g')
	SEND_MAIL "temp=error" "err=$ERR_TEXT" 
}
LOG() {
	[ "$VERBOSE" == "1" ] && echo "[$(date +"%Y-%m-%d %H:%M:%S") $$] $@"
}
function cmdexe {
[[ "$LOCAL" == "0" ]] && ssh ${USER}@${IP} -i $SSH_KEY -o PasswordAuthentication=no -o StrictHostKeyChecking=no "$1" || eval $@
}
function SEND_MAIL { #Args
	[[ -z $MAIL_TO ]] && { [[ "$XVERBOSELOG" == "1" ]] && LOG "Sending mail disabled."; return 0; }
	while [[ $# -gt 0 ]]; do
		local MAIL_ARG+="&$1"
		shift
	done
	LOG "Mail args: $MAIL_ARG"
	echo "$MAIL_TO" | grep ':' >/dev/null 2>&1 && {
		for mailto in $(echo $MAIL_TO | tr ':' '\n'); do 
			LOG "Sending to $mailto"
			curl "http://backupmon.example.ua/localmail/send.php?server=${HS}&mail=${mailto}&lang=${MAIL_LANG}$MAIL_ARG"
			sleep 5
		done
	} || { curl "http://backupmon.example.ua/localmail/send.php?server=${HS}&lang=${MAIL_LANG}&mail=${MAIL_TO}$MAIL_ARG"; LOG "Sending to $MAIL_TO"; }
}
HS=$(hostname)
LOCAL=0
QUOTA=0
DELETE_OLD=0
FORECAST=0
MAIL_TYPE=10
MAIL_LANG="UA"
SSH_PORT=22
SSH_KEY=~/.ssh/id_rsa
USER=root
RSYNC_ARG="-a --exclude=/tmp --exclude=/var/tmp --exclude=/mnt --exclude=/dev --exclude=/run --exclude=/sys --exclude=/home*/virtfs --exclude=/proc --exclude=/home/cagefs-skeleton --exclude=/var/cagefs --exclude=/usr/share/cagefs-skeleton* --exclude=/usr/share/cagefs --exclude=/home*/*/.cagefs/tmp"
TAR_ARG="-c"
TAR_FORMAT="tar"
INC=1
FORCE=0
FORECAST_N=3
XVERBOSE=0
PUSER=postgres
PAUTH=unix
PDUMP=raw
PPORT=5432
while [[ $# -gt 0 ]]; do
	case "$1" in
		--src|-S)
			echo $2 | grep '^/' > /dev/null 2>&1 || { MAILERR "Path $2 is not absolute path"; exit 1; }
			if [ "$2" == "/" ]; then
			DIRS+="$2 "
			else
			DIRS+="${2%/} "
			fi
			shift
			shift
			;;
		--dst|-D)
			[ "$2" == "/" ] && MAILERR "Destenation dir set to /" && exit 1
			echo $2 | grep '^/' > /dev/null 2>&1 || { MAILERR "Path $2 is not absolute path"; exit 1; }
			DEST="${2%/}"
			shift
			shift
			;;
		-R)
			RSYNC_ARG+=" -R"
			shift
			;;
		-E|--exclude)
			RSYNC_ARG+=" --exclude $2"
			TAR_ARG+=" --exclude=$2"
			shift
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		--mount)
			echo $2 | grep -E "^M:|^D:/dev/|^L:" > /dev/null 2>&1 || { MAILERR "You must set mount type: L: or D: or M:"; echo "Use $0 --help to see more information";  exit 1; }
			MOUNTPOINT="$2"
			shift
			shift
			;;
		-l|--local)
			LOCAL=1
			shift
			;;
		-p|--psql)
			PSQL=1
			cmdexe "which psql" >/dev/null 2>&1 || { MAILERR "PostgreSQL may not be installed: psql unknown command"; exit 1; }
			shift
			;;
		--pzip)
			PSQL_ZIP=1
			shift
			;;
		--puser)
			PUSER="$2"
			shift
			shift
			;;
		--ppass)
			PPASS="$2"
			shift
			shift
			;;
		--pauth)
			PAUTH="${2,,}"
			echo "$PAUTH" | grep -E "^unix$|^pass$" >/dev/null || { MAILERR "PAUTH [$PAUTH] value is not correct. Only pass or unix is avalible"; exit 1; }
			shift
			shift
			;;
		--pdump)
			PDUMP="${2,,}"
			echo "$PDUMP" | grep -E "^raw$|^bin$" >/dev/null || { MAILERR "PDUMP [$PDUMP] value is not correct. Only raw or bin is avalible"; exit 1; }
			shift
			shift
			;;
		--pport)
			PPORT="$2"
			shift
			shift
			;;
		-s|--sql)
			SQL=1
			shift
			;;
		-z|--sqlzip)
			cmdexe "which gzip" > /dev/null 2>&1 || { MAILERR "gzip is not installed."; exit 1; }
			SQL_ZIP=1
			shift
			;;
		-k|--ssh-key)
			[[ "$LOCAL" == "1" ]] && { MAILERR "Use local OR remote backup."; exit 1; }
			SSH_KEY="$2"
			shift
			shift
			;;
		-p|--ssh-port)
			[[ "$LOCAL" == "1" ]] && { MAILERR "Use local OR remote backup."; exit 1; }
			SSH_PORT="$2"
			shift
			shift
			;;
		-u|--user)
			[[ "$LOCAL" == "1" ]] && { MAILERR "Use local OR remote backup."; exit 1; }
			USER="$2"	
			shift
			shift
			;;
		--mail)
			which curl > /dev/null 2>&1 || { MAILERR "curl is not installed"; exit 1; }
			MAIL_TO=$2
			shift
			shift
			;;
		--mail-type)
			MAIL_TYPE=$2
			shift
			shift
			;;
		--mail-lang)
			MAIL_LANG=${2^^}
			shift
			shift
			;;
		--gz)
			TAR_ARG+=" -z"
			TAR_FORMAT="tar.gz"
			shift
			;;
		--real-calc)
			REAL_Q=1
			shift
			;;
		-i|--ip)
			[[ "$LOCAL" == "1" ]] && { MAILERR "Use local OR remote backup."; exit 1; }
			IP="$2"
			ping -c2 -W2 $IP > /dev/null 2>&1 || echo "WARNING: IPv4 $IP cannot be pinged."
			shift
			shift
			;;
		-o|--owner)
			OWNER="$2"
			grep ^${OWNER}: /etc/passwd > /dev/null || { MAILERR "User $OWNER does not exist in system" && exit 1; }
			shift
			shift
			;;
		--notify)
			which curl > /dev/null 2>&1 || { MAILERR "curl is not installed"; exit 1; }
			NOTIFY=1
			shift
			;;
		--hostname)
			HS="$2"
			shift
			shift
			;;
		-f|--full)
			INC=0
			shift
			;;
		-I|--io)
			IO=${2//[^0-9]/}
			RSYNC_ARG+=" --bwlimit=${IO}MB"
			shift
			shift
			;;
		-d|--delete-old)
			echo $2 | grep -iE "M$|D$" > /dev/null || { MAILERR "You must set D or M after number for -d|--delete-old key" && exit 1; }
			DELETE_OLD=${2//[^0-9]/}
			echo $2 | grep -i "M$" >/dev/null && DELETE_OLD_TYPE=Min && FIND_ARG="-mmin +$DELETE_OLD -print"
			echo $2 | grep -i "D$" >/dev/null && DELETE_OLD_TYPE=Day && FIND_ARG="-mtime +$DELETE_OLD -print"
			shift
			shift
			;;
		--dry)
			DRY=1
			RSYNC_ARG+=" --dry-run"
			shift
			;;
		-t|--timestamp)
			FULL_ISO=1
			shift
			;;
		-q|--quota)
			QUOTA="$2"
			[[ $QUOTA == *dev* ]] && {
				QUOTA_DRIVE="$2"
				df $2 >/dev/null 2>&1 || { MAILERR "Block device $2 not found"; exit 1; }
				QUOTA=$(df -m --output=size $2 | tail -n1 | awk '{$1=$1; print}')
				QUOTA=$(( $QUOTA * 9 / 10))
			}
			shift
			shift
			;;
		-F|--forecast)
			FORECAST=1
			shift
			;;
		--forecast-number)
			FORECAST_N=$2
			shift
			shift
			;;
		-h|--help)
			echo "$USAGE"
			exit 0
			;;
		-a|--archive)
			ARCHIVE=1
			shift
			;;
		-e|--custom-exclude)
			EXCLUDE="$2"
			[ ! -f $EXCLUDE ] && MAILERR "Exclude file $EXCLUDE does not exist" && exit 1
			RSYNC_ARG+=" --exclude-from=$2"
			TAR_ARG+=" -X=$2"
			shift
			shift
			;;
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		-V|--extra-verbose)
			XVERBOSE=1
			RSYNC_ARG+=" -vP"
			TAR_ARG+=" -v"
			shift
			;;
		*) # Unknown option
			echo "Unknown option: $1"
			exit 1
			;;
	esac
done
if [[ "$PDUMP" == "bin" && "$LOCAL" != "1" ]]; then
	MAILERR "Binary PDUMP avalible only on local-to-local backup type (key -l | --local"
	exit 1
fi
if [[ "$PSQL_ZIP" == "1" && "$PDUMP" == "bin" ]]; then
	ERR "Use only one: PSQL_ZIP=yes or PDUMP=bin at one time"
	exit 1
fi
which rsync > /dev/null 2>&1 || { MAILERR "rsync is not installed"; exit 1; }
[[ "$DRY" != "1" ]] && FIND_ARG+=" -exec rm -rf {} +"
[[ -z $DIRS ]] && DIRS=0
if [ "$FULL_ISO" == "1" ];then
	ISO=$(date +"%F_%H-%M")
else
	ISO=$(date --iso)
fi
if [[ "$LOCAL" == "0" ]]; then
	which telnet > /dev/null 2>&1 || { MAILERR "telnet is not installed"; exit 1; }
	telnet -4 -ee $IP $SSH_PORT <<<"e" >/dev/null 2>&1 || { MAILERR "Connect to TCP:$IP:$SSH_PORT failed" && exit 1; }
fi

[[ "$LOCAL" == "1" ]] && RSYNC_ARG+=" --exclude $DEST" && TAR_ARG+=" --exclude=$DEST"
function PRINT_VARS {
	[[ "$VERBOSE" == "1" ]] || return 0
	local VARS=(DIRS DEST SQL REAL_Q SQL_ZIP PSQL PSQL_ZIP PUSER PPORT PPASS PDUMP PAUTH LOCAL SSH_KEY SSH_PORT USER IP OWNER MOUNTPOINT INC ARCHIVE FULL_ISO IO DRY XVERBOSE DELETE_OLD DELETE_OLD_TYPE QUOTA EXCLUDE NOTIFY HS FORCE FORECAST FORECAST_N MAIL_TO MAIL_TYPE MAIL_LANG)
	for var in "${VARS[@]}"; do
		[[ -n ${!var} ]] && printf "\t%-20s %s\n"	"$var" "${!var}"
	done
}

function CALC_FORECAST {
	[[ "$FORECAST" != "1" ]] && { LOG "Forecast disabled."; return 0; }
	[[ "$QUOTA" == "0" ]] && { LOG "Quota set as 0, so forecast also disabled."; return 0; }
	if [[ "$INC" == "1" ]] && [[ "$ARCHIVE" != "1" ]]; then 
		if [[ -f $DEST/.forecast_$HASH ]]; then
			local values=($(cat $DEST/.forecast_$HASH | grep -viE "total|sql|tar" | sort -nr | sed '1d' | sort -k2 | awk {'print $1'} | tail -n${FORECAST_N}))
		else
			local values_num=$(($FORECAST_N + 1))
			local values_dir=$(ls -1 $DEST | grep ^20 | grep -vE "sql|tar" | sort -k2 | tail -n${values_num})
			[[ ${#values_dir[@]} -lt $values_num ]] && { echo "Backups count are not enough to forecast"; return 0; }
			local values=($(du -sm $values_dir | sort -nr | sed '1d' | sort -k2  | awk {'print $1'}))
		fi
	elif [[ "$INC" == "0" ]] && [[ "$ARCHIVE" != "1" ]]; then
		[[ -f $DEST/.forecast_$HASH ]] || { echo "Forecast file not found: $DEST/.forecast_$HASH"; return 0; }
		local values=($(cat $DEST/.forecast_$HASH | awk {'print $1'} | tail -n${FORECAST_N}))
	fi
	local n=${#values[@]}
	[[ $n -lt 2 || $n -lt $FORECAST_N ]] && { echo "Forecast number $n smaller than 2 or FORECAST_N: $FORECAST_N"; return 0; }
	local sum_x=0
	local sum_y=0
	local sum_xy=0
	local sum_x2=0
	for ((i=0; i<n; i++)); do
	    local x=$i
	    local y=${values[i]}
	    local sum_x=$((sum_x + x))
	    local sum_y=$((sum_y + y))
	    local sum_xy=$((sum_xy + x * y))
	    local sum_x2=$((sum_x2 + x * x))
	done
	local m=$(( (n * sum_xy - sum_x * sum_y) / (n * sum_x2 - sum_x * sum_x) ))
	local b=$(( (sum_y - m * sum_x) / n ))
	local next_x=$n
	FORECAST_NEXT=$((m * next_x + b))
	FORECAST_NEXT="${FORECAST_NEXT//[!0-9]/}"	
	LOG "Forecasted next value: $FORECAST_NEXT Old quota: $QUOTA"
	#FORECAST_NEXT=${FORECAST_NEXT%%.*}
	if (( $QUOTA > $FORECAST_NEXT )); then
		    QUOTA=$(($QUOTA - $FORECAST_NEXT))
	fi
	[[ "$SQL" == "1" ]] && {
		local SQL_LAST=$(ls -1 $DEST | grep '20.*sql' | tail -1)
		[[ -n $SQL_LAST ]] && {
			local SQL_SIZE=$(du -sm $DEST/$SQL_LAST | awk {'print $1'})
			LOG "Quota - last sql_size: $QUOTA - $SQL_SIZE"
			QUOTA=$(($QUOTA - $SQL_SIZE))
		}
	}
	LOG "New quota: $QUOTA"
}
function CALC_DEST_SIZE {
	LOG "Calculating destenation directory ${DEST} size..."
	[[ -n $QUOTA_DRIVE ]] && {
		LOG "Using $QUOTA_DRIVE to get USE and FREE size"
		DEST_SIZE=$(df -m --sync --output=used $QUOTA_DRIVE | tail -n1 | awk '{$1=$1; print}')
		return 0;
	}
	if [[ "$REAL_Q" == "1" ]]; then
		LOG "Calculating real $DEST size..."
		DEST_SIZE=$(du -sm $DEST | awk {'print $1'})
	else
		LOG "Trying to get cached total size from forecast file"
		DEST_SIZE=$(cat $DEST/.total_$HASH)
		[[ -z $DEST_SIZE ]] && { LOG "Cache size not found. Calculating real size..."; DEST_SIZE=$(du -sm $DEST | awk {'print $1'}); echo $DEST_SIZE > $DEST/.total_$HASH; }
	fi
}
function PSQL_DUMP {
	LOG "Starting dumping PSQL databases"
	if [[ "$PAUTH" == "unix" ]]; then
		RUNUSER=$(find /*/*bin* -iname 'runuser' -executable -type f)
		if [[ -z $RUNUSER ]]; then
			RUNUSER=/usr/sbin/runuser
		fi
		cmdexe "which sudo" >/dev/null 2>&1 && PRE_SQL="sudo -u $PUSER" || PRE_SQL="$RUNUSER -u $PUSER --"
	elif [[ "$PAUTH" == "pass" ]]; then
		PRE_SQL=""
		if [[ -n $PPASS ]]; then
			LOG "Editing ~/.pgpass file..."
			cmdexe "echo \"*:*:*:$PUSER:$PPASS\" > ~/.pgpass; chmod 600 ~/.pgpass"
		fi
	else
		LOG "Auth method [$PAUTH] is unknown. Skipping PGSQL dump..."
		return 0;
	fi
	cmdexe "$PRE_SQL psql -p $PPORT -U $PUSER -c ''" >/dev/null && {
		LOG "Successful connection to PGSQL"
	} || {
		LOG "Failed to connect to PGSQL. Skipping PGSQL dump...";
		return 0;
	}
	mkdir -p ${DEST}/${ISO}_psql
	for db in $(cmdexe "$PRE_SQL psql -p $PPORT -U $PUSER -Atc 'SELECT datname FROM pg_database WHERE datistemplate = false;'"); do
		if [[ "$PDUMP" == "raw" ]];then
			if [[ "$PSQL_ZIP" == "1" ]];then
				cmdexe "$PRE_SQL pg_dump -U $PUSER -p $PPORT $db" | gzip > ${DEST}/${ISO}_psql/${db}.sql.gz
			else
				cmdexe "$PRE_SQL pg_dump -U $PUSER -p $PPORT $db" > ${DEST}/${ISO}_psql/${db}.sql
			fi
		elif [[ "$PDUMP" == "bin" ]];then
			$PRE_SQL pg_dump -p $PPORT -U $PUSER -Fc $db -f ${DEST}/${ISO}_psql/${db}.dump
		else
			LOG "Unkown PGDUMP [$PDUMP] value. Skipping PGSQL dump..."
			return 0;
		fi
		LOG "Database [$db] dumped: $(du -sh ${DEST}/${ISO}_psql/${db}\.*)"
	done
	LOG "PGSQL dump ended"
}
function DELETE_OVER_QUOTA {
	if [[ "$QUOTA" != "0" ]]; then
		if [[ $QUOTA == *dev* ]]; then
			:
		else
			QUOTA="${QUOTA//[^0-9]/}"
			CALC_DEST_SIZE
			LOG "Quota set as ${QUOTA}M and destenation directory has ${DEST_SIZE}M size"
			while [ "$DEST_SIZE" -gt "$QUOTA" ]; do
				CALC_DEST_SIZE
				DEL_DIR=$(ls -1 $DEST | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" | head -n1)
				if [[ $DEST_SIZE -le $QUOTA ]]; then
					LOG "Destenation directory size [${DEST_SIZE}M] smaller than quota [${QUOTA}M]. Exiting while loop..."
					break
				fi
				[[ "$DRY" == "1" ]] && LOG "WARNING: Dry mode enable, overquota backups will not be deleted" && break
				if [[ "$INC" == "0" ]]; then
					DEL_SIZE=$(grep "$DEL_DIR$" $DEST/.forecast_$HASH | awk {'print $1'})
					[[ -z $DEL_SIZE ]] && DEL_SIZE=$(du -sm $DEST/$DEL_DIR | awk {'print $1'})
				elif [[ -z $QUOTA_DRIVE ]]; then
					grep "${DEL_DIR}$" $DEST/.forecast_$HASH 1>&2 2>/dev/null && { DEL_SIZE=$(grep "${DEL_DIR}$" $DEST/.forecast_$HASH | awk {'print $1'}); } || { HEAD=$(ls -1 $DEST | grep ^20 | grep -vE "sql|tar" | head -n2 | tail -n1); DEL_SIZE=$(du -sm $DEST/$HEAD $DEST/$DEL_DIR | grep $DEL_DIR | awk {'print $1'}); }
				fi
				[[ "$DRY" != "1" ]] && {
					LOG "Destanation directory ${DEST} size [${DEST_SIZE}M] greater than quota [${QUOTA}M]. Deleting $DEST/$DEL_DIR	${DEL_SIZE}MB"
					if [[ -n $DEL_SIZE ]]; then
						DELETE_OLD_COUNT=$(( $DELETE_OLD_COUNT + 1 ))
						DEST_SIZE=$(( $DEST_SIZE - $DEL_SIZE ))
						echo $DEST_SIZE > $DEST/.total_$HASH
						grep -v "$DEL_DIR$" $DEST/.forecast_$HASH > $DEST/.tmp_$HASH
						cat $DEST/.tmp_$HASH > $DEST/.forecast_$HASH
					fi
					rm -rf $DEST/$DEL_DIR && sleep 10
				}
			done
		fi
	else
		LOG "Deleting overquota disabled. Skipping..."
	fi
}
function DELETE_OLD_BACKUP { 
	if [ "$DELETE_OLD" != "0" ]; then
		LOG "Removing backups older than ${DELETE_OLD} ${DELETE_OLD_TYPE}..."
		LOG "Fixing timestamps"
		for i in $(ls -1 $DEST | grep -vi sql | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}"); do
			UBUNTU_TS=$(echo "$(echo $i | cut -c 3-)$(date +%H%M)")
			DEF_TS=$(echo $i | grep [0-9] -o | tr -d '\n')
			touch -d $i $DEST/$i* || touch -t $DEF_TS $DEST/$i* || touch -t $UBUNTU_TS $DEST/$i*
		done
		[[ "$DRY" == "1" ]] && LOG "WARNING: Dry mode enable, old backups will not be deleted"
		LOG "Deleting next backups:"
		find $DEST -maxdepth 1 -mindepth 1 -type d -iname '2[0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' $FIND_ARG | sort
		LOG "Removing old backups complete."
	else
		LOG "Deleting old backups disabled. Skipping..."
	fi
}

function remount {
if [[ -n "$MOUNTPOINT" ]]; then
	local MOUNTDATA=${MOUNTPOINT#*:}
	LOG "Remount $MOUNTDATA to read-write/only-read"
#	sleep 5
	echo $MOUNTPOINT | grep '^D:/dev/' > /dev/null 2>&1 && {
		LOG "$MOUNTPOINT identified as device. Remounting $1"
		lsblk -nro NAME | grep "${MOUNTDATA##*/}$" > /dev/null 2>&1 || { MAILERR "Device $MOUNTDATA not found"; exit 1; }
		mount -o remount,$1 $MOUNTDATA
	}
	echo $MOUNTPOINT | grep '^M:' > /dev/null 2>&1 && {
		LOG "$MOUNTPOINT identified as mountpoint. Remounting $1"
		df --output=target | grep "^${MOUNTDATA}$" > /dev/null 2>&1 || { MAILERR "Mountpoint $MOUNTDATA not found"; exit 1; }
		mount -o remount,$1 $MOUNTDATA
	}
	echo $MOUNTPOINT | grep '^L:' > /dev/null 2>&1 && {
		LOG "$MOUNTPOINT identified as label. Remounting $1"
		lsblk -nro LABEL | grep "^${MOUNTDATA}$" > /dev/null 2>&1 || { MAILERR "Label $MOUNTDATA not found"; exit 1; }
		mount -o remount,$1 -L $MOUNTDATA
	}
else
	LOG "Remount to rw/ro disabled. Skiping..."
fi
}
LOG "=============== Starting backup ==============="
LOG "Variables set as:"
PRINT_VARS
[[ $MAIL_TYPE == 2* ]] && SEND_MAIL "temp=start"
HASH=$(echo "$DEST $ARCHIVE $FULL_ISO" | md5sum | awk {'print $1'})
if [[ "$FORCE" != "1" ]];then
	for PID in $(cat $DEST/.hash_$HASH 2>/dev/null); do
		ps x | awk {'print $1'} | grep "^${PID}$" > /dev/null 2>&1 && { LOG "Another copy of this program [PID: $PID] still running..."; exit 1; }
	done
fi
remount rw
mkdir -p $DEST
touch $DEST/.write_test && rm -f $DEST/.write_test || { MAILERR "Cannot write into $DEST"; exit 1; }
echo "$$" >> $DEST/.hash_${HASH}

[[ -n "$OWNER" ]] && RSYNC_ARG+=" --no-owner --no-group"
LOG "RSYNC ARG: $RSYNC_ARG"
LOG "TAR ARG: $TAR_ARG"







[[ "$LOCAL" == "0" ]] && for dir in $DIRS; do FROM+="${USER}@${IP}:$dir "; done || for dir in $DIRS; do FROM+="$dir "; done
[ "$DIRS" != "0" ] && FROM=${FROM% } && LOG "FROM: $FROM"
if [[ "$LOCAL" == "0" ]]; then
	[ -z $IP ] && MAILERR "IPv4 address is not set." && exit 1
	LOG "SSH testing connection [${USER}@${IP}] with key ${SSH_KEY}..."
	[ ! -f ${SSH_KEY} ] && MAILERR "SSH key file $SSH_KEY does not exist" && exit 1
	chmod 600 ${SSH_KEY}*
	[[ "$VERBOSE" == "1" ]] && REMOTE_CMD="date;uname -a" || REMOTE_CMD="date > /dev/null"
	ssh ${USER}@${IP} -i $SSH_KEY -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$REMOTE_CMD" && LOG "...successful" || exit 1
fi

CALC_FORECAST
[[ "$FORECAST" == "1" ]] && DELETE_OVER_QUOTA


DELETE_OLD_BACKUP
if [ "$DIRS" != "0" ]; then
	[ -z $DEST ] && MAILERR "Destenation directory is not set." && exit 1



#######
	Today=$(date +%A)
	[[ "$NOTIFY" == "1" ]] && { LOG "Send notify about start"; curl "http://backupmon.example.ua/backuplocal.php?server=${HS}&day=$Today&action=begin"; }

	if [[ "$ARCHIVE" != "1" ]]; then
		LOG "Starting copying data from [$FROM] to [$DEST/$ISO] via rsync..."
		if [ "$INC" == "1" ]; then 
			LAST=$(cat $DEST/.mirror_$HASH)
			mkdir -p $DEST/$ISO
			LOG "Making incremental backup from [$FROM] using hard links. Mirror=$LAST"
			if [[ "$LOCAL" == "1" ]]; then
				rsync $RSYNC_ARG --link-dest=../${LAST} $FROM $DEST/$ISO --stats > $DEST/.rsync_$HASH 2>&1
			else
				rsync $RSYNC_ARG -e "ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -i $SSH_KEY -p $SSH_PORT" --link-dest=../${LAST} $FROM $DEST/$ISO --stats > $DEST/.rsync_$HASH 2>&1
			fi
		else
			mkdir -p $DEST/$ISO
			if [[ "$LOCAL" == "1" ]]; then
				rsync $RSYNC_ARG  $FROM $DEST/$ISO --stats > $DEST/.rsync_$HASH 2>&1
			else
				rsync $RSYNC_ARG -e "ssh -o PasswordAuthentication=no -o StrictHostKeyChecking=no -i $SSH_KEY -p $SSH_PORT" $FROM $DEST/$ISO --stats > $DEST/.rsync_$HASH 2>&1
			fi
		fi
		echo "$ISO" > $DEST/.mirror_$HASH
		touch $DEST/$ISO
	elif [[ "$ARCHIVE" == "1" ]]; then
		mkdir -p $DEST
		LOG "Copying backup from [$DIRS] into archive $DEST/${ISO}.$TAR_FORMAT"
		cmdexe "tar $TAR_ARG -f - $DIRS 2>/dev/null | cat" > $DEST/${ISO}.$TAR_FORMAT
	fi
#######

else
	LOG "File backup disable. Skipping..."
fi
#
##sleep 2
sleep 2
if [[ "$SQL" -eq "1" ]]; then
	LOG "Creating SQL dumps"
	mkdir -p ${DEST}/${ISO}_sql
	DB_LIST=$(cmdexe "mysql -s -e 'show databases' | grep -vE \"Database|information_schema|mysql|performance_schema\"")
	LOG "Database list:" $DB_LIST
	mkdir -p ${DEST}/${ISO}_sql
	for db in $DB_LIST; do
		if [[ "$SQL_ZIP" -eq "1" ]]; then
			LOG "Dumping database $db into $DEST/${ISO}_sql/${db}.sql.gz..."
			cmdexe "mysqldump $db" | gzip > ${DEST}/${ISO}_sql/${db}.sql.gz
			LOG "Done: $(ls -lh ${DEST}/${ISO}_sql/${db}.sql.gz | awk {'print $5,$9'})"
		else
                        LOG "Dumping database $db into $DEST/${ISO}_sql/${db}.sql..."
			cmdexe "mysqldump $db" > ${DEST}/${ISO}_sql/${db}.sql 
			LOG "Done: $(ls -lh ${DEST}/${ISO}_sql/${db}.sql | awk {'print $5,$9'})"
		fi
	done
else
	LOG "SQL set to 0. Skipping SQL dump..."
fi
if [[ "$PSQL" == "1" ]]; then
	PSQL_DUMP
fi
#
sleep 2
[[ "$NOTIFY" == "1" ]] && { LOG "Send notify about end"; curl "http://backupmon.example.ua/backuplocal.php?server=${HS}&day=$Today&action=end"; }

if [[ -n "$OWNER" ]]; then
LOG "Setting owner for $DEST/${ISO}* to $OWNER"
chown $OWNER: $DEST
chown -R $OWNER: $DEST/${ISO}*
fi

[[ "$FORECAST" != "1" ]] && DELETE_OVER_QUOTA

BACKUP_LIST=$(ls -1 $DEST | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" | tr '\n' ':')
BACKUP_LIST=${BACKUP_LIST%:}
SEND_MAIL "temp=done" "list=$BACKUP_LIST"


#### Calc forecast size
[[ "$FORECAST" == "1" ]] && {
	LOG "Calculating new backup $DEST/$ISO for next forecast"
	if [[ "$INC" != "1" ]] && [[ "$ARCHIVE" != "1" ]]; then 
		LOG "Non-incremental way: calculating $DEST/$ISO"
		NEW_ISO_SIZE=$(du -sm $DEST/$ISO)
		NEW_ISO_PATH=$(echo $NEW_ISO_SIZE | awk -F'/' {'print $NF'})
		NEW_ISO_SIZE=$(echo $NEW_ISO_SIZE | awk {'print $1'})
		echo "$NEW_ISO_SIZE	$NEW_ISO_PATH" >> $DEST/.forecast_$HASH
		cat $DEST/.forecast_$HASH | awk '{sum += $1} END {print sum}' > $DEST/.total_$HASH
	elif [[ "$INC" == "1" ]] && [[ "$ARCHIVE" != "1" ]];then 
		BACKUP_COUNT=$(ls -1 $DEST | grep -viE "sql|tar" | wc -l)
		if [[ $BACKUP_COUNT -lt 4 || $DELETE_OLD_COUNT -ge 3 ]]; then
			[[ -z $QUOTA_DRIVE ]] && {
				LOG "Backup count less than 4 or DELETE_OLD_COUNT more than 3. Calculating whole $DEST"
				cd $DEST; du -smc 20* | grep -viE "sql|tar" > $DEST/.tmp_$HASH
				grep -vi total $DEST/.tmp_$HASH > $DEST/.forecast_$HASH
				grep -i total $DEST/.tmp_$HASH | awk {'print $1'} > $DEST/.total_$HASH
			}
		else
			LOG "Backup count more than 4. Calculating only $DEST/$ISO"
			HEAD=$(ls -1 $DEST | grep ^20 | grep -vE "sql|tar" | head -n1)		
			LAST=$(ls -1 $DEST | grep ^20 | grep -vE "sql|tar" | tail -n2 | head -n1)		
			NEW_ISO_SIZE=$(du -sm $DEST/$HEAD $DEST/$LAST $DEST/$ISO | grep $ISO)
			NEW_ISO_PATH=$(echo $NEW_ISO_SIZE | awk -F'/' {'print $NF'})
			NEW_ISO_SIZE=$(echo $NEW_ISO_SIZE | awk {'print $1'})
			echo "$NEW_ISO_SIZE	$NEW_ISO_PATH" >> $DEST/.forecast_$HASH
			OLD_TOTAL=$(cat $DEST/.total_$HASH)
			NEW_TOTAL=$(( $OLD_TOTAL + $NEW_ISO_SIZE ))
			LOG "New $DEST size: $OLD_TOTAL + $NEW_ISO_SIZE = $NEW_TOTAL"
			echo $NEW_TOTAL > $DEST/.total_$HASH
		fi
	fi
	if [[ "$ARCHIVE" == "1" ]]; then
		du -sm $DEST/${ISO}.$TAR_FORMAT >> $DEST/.forecast_$HASH
	fi
}

BACKUP_DRIVE=$(df --output=source $DEST | awk 'NR > 1' | awk -F'/' {'print $NF'})
BACKUP_USE=$(df --output=pcent $DEST | awk 'NR > 1')
BACKUP_USE="${BACKUP_USE//[^0-9]/}"
if (( $BACKUP_USE > 90 )); then
	MAILERR "Backup drive $BACKUP_DRIVE has $BACKUP_USE disk space use."
fi

grep -v "^$$$" $DEST/.hash_$HASH > $DEST/.hash_${HASH}_tmp 2>/dev/null
cat $DEST/.hash_${HASH}_tmp > $DEST/.hash_$HASH 2>/dev/null
rm -f $DEST/.hash_${HASH}_tmp

remount ro
LOG "=============== Backup complete ==============="
