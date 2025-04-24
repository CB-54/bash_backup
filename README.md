Create local-to-local or remote-to-local files backup via rsync.
This bash script supports:
- incremental backup (using hard link)
- Full backup
- backup of MySQL/MariaDB databases
- backup of PSQL databases
- database compression (gzip for PSQL/MySQL, gzip/binary for PSQL)
- saving backups to the archive (tar/tar.gz)
- change the unix owner of the backup
- notifications about the start/end and errors of backup via e-mail
- deleting old backups by date of expiration
- deleting old backups by backup directory size
- deleting old backups by backup disk usage
