Create local-to-local or remote-to-local files backup via rsync.
This bash script supports:
- incremental backup (using hard link)
- backup of MySQL/MariaDB databases
- database compression
- saving backups to the archive
- change the unix owner of the backup
- notifications about the start/end and errors of backup via e-mail
- deleting old backups by date of expiration
- deleting old backups by backup directory size
