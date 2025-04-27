#!/bin/bash
# envs to override
# backup_dir="/backup"
# remote_backup_dir="/backup"
# db_user=""
# db_pass=""
# db_port=""
# vg_name="storage"
# lv_nextcloud="lv-storage"
# www_dir="/var/www/nextcloud"
# ftp_user=backup
# ftp_pass=
# ssh_user=
# remote_host=backup
# remote_mac=[mac address]
# backup=1
# announce=1
# announce_user=
# clean=1
# min_days=15
# backup_count=2
# backup_type=rsync
# snaphot_size=10G
# web_server_conf=/etc/apache2
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
announce_message=""
announce_message_title=""
m_error() {
  echo -e "${RED}$1${NC}"
  if [[ "$2" == 1 ]]; then
    announce_message+="$1
    "
  fi
}
m_warn() {
  echo -e "${YELLOW}$1${NC}"
  if [[ "$2" == 1 ]]; then
    announce_message+="$1
    "
  fi
}
m_ok() {
  echo -e "${GREEN}$1${NC}"
  if [[ "$2" == 1 ]]; then
    announce_message+="$1
    "
  fi
}
m_normal() {
  echo -e "${NC}$1${NC}"
}
failed_backup() {
  announce_message_title+="failed!"
}
send_message () {
  m_normal "Sending message to $announce_user"
  sudo -u www-data php /var/www/nextcloud/occ notification:generate $announce_user "$announce_message_title" -l "$announce_message"
}
backup_exception() {
  m_error "$1"
  failed_backup
  announce_message+="$1"
  send_message
  exit $2
}

[[ ! -f "$1" ]] && m_error "Missing config file" && exit 0
source $1
[[ ! "$backup_type" =~ (ftp|rsync) ]] && m_error "Not supported backup type: $backup_type" && exit 2137
if [[ "$backup_type" == "ftp" ]]; then
  which lftp >/dev/null
  [[ "$?" -ne 0 ]] && m_error "lftp has to be installed" && exit 201
fi
# TODO
# backup_start=`date +%s`
tries=0
server_up=0
date=`date "+%Y-%m-%d"`
announce_message_title+="Backup status for ${date}: "
while [[ ${tries} -le 10 ]]; do
  echo "Waking up remote server"
  sudo /usr/sbin/etherwake -i end0 $remote_mac
  echo "Magic packet sent. Waiting..."
  sleep 60
  ping -c 1 -W 3 $remote_host &>/dev/null
  result=$?
  if [[ $result -ne 0 ]]; then
    let tries++
  else
    m_ok "Server up!"
    server_up=1
    break
  fi
done
[[ "$server_up" -eq 0 ]] && backup_exception "Remote server not started. Exiting." 1
m_normal "Checking if i can connect to service $backup_type on $remote_host."
if [[ "${backup_type}" == "ftp" ]]; then
  lftp -u ${ftp_user},${ftp_pass} $remote_host -e "ls $backup_dir/; bye;" &> /dev/null
  [[ "$?" -ne 0 ]] && backup_exception "Couldn't connect to $remote_host over ftp" 101
elif [[ "${backup_type}" == "rsync" ]]; then
  ssh ${ssh_user}@${remote_host} -o ConnectTimeout=10 -o ConnectionAttempts=3 "ls ${remote_backup_dir}" &> /dev/null
  [[ "$?" -ne 0 ]] && backup_exception "Couldn't connect to $remote_host over ssh" 102
fi
if [[ "$backup" -eq 1 ]]; then
  m_normal "Creating directory"
  curr_backup_dir="${backup_dir}/nextcloud-$date/"
  remote_curr_backup_dir="${remote_backup_dir}/nextcloud-$date/"
  mount_snapshot="${backup_dir}/nextcloud-$date/storage"
  mkdir -p "${curr_backup_dir}/db/" "${mount_snapshot}"
  m_normal "Created: $curr_backup_dir"
  m_warn "PHP maintenance ON. Nextcloud not accepting connection."
  sudo -u www-data php ${www_dir}/occ maintenance:mode --on
  status=$?
  [[ $status != 0 ]] && backup_exception "Error during enabling maintenance mode!" 2
  m_warn "Maintanance mode enabled."

  m_normal "Database dump"
  /usr/bin/mysqldump --single-transaction -u "$db_user" -p"$db_pass" nextcloud > "${curr_backup_dir}/db/nextcloud-sqlbkp.bak"
  [[ $? != 0 ]] &&  backup_exception "Error during making database dump!" 3
  m_ok "Database dump ok!"

  m_normal "Creating nextcloud snapshot"
  sudo /usr/sbin/lvcreate --size $snapshot_size --name backup-$date --snapshot /dev/$vg_name/$lv_nextcloud
  [[ $? != 0 ]] && backup_exception "Error during creating snapshot!" 4
  [[ ! -L /dev/$vg_name/backup-$date ]] && backup_exception "Snapshot /dev/$vg_name/backup-$date doesn't exists. Error!" 5
  m_ok "Ok!. Snapshot created!"

  m_normal "Mounting snapshot under $mount_snapshot"
  sudo /usr/bin/mount -o nouuid /dev/$vg_name/backup-$date $mount_snapshot
  [[ $? != 0 ]] && backup_exception "Error during mounting snapshot!" 6
  [[ -z "`/usr/bin/mount | grep $mount_snapshot`" ]] && backup_exception "Error during mounting snapshot" 7
  m_ok "Ok! Mounted!"

  m_normal "Php maintenance OFF"
  sudo -u www-data php ${www_dir}/occ maintenance:mode --off
  [[ $? != 0 ]] && backup_exception "Error during disabling maintenance mode! Nextcloud may not accepting requests." 8
  m_ok "OFF nextcloud accepting connections from now"

  m_normal "Copying files to backup server over $backup_type."
  if [[ "$backup_type" == "rsync" ]]; then
    m_normal "Creating remote directories for backup"
    for dir in "${remote_curr_backup_dir}/db/" "${remote_curr_backup_dir}/storage/"; do
      ssh ${ssh_user}@${remote_host} "mkdir -p $dir"
    done
  fi
  m_normal "Backing up database."
  if [[ "$backup_type" == "ftp" ]]; then
    lftp -u ${ftp_user},${ftp_pass} $remote_host -e "mirror -R ${curr_backup_dir}/db/ ${remote_curr_backup_dir}/db/; bye" 
    db_status=$?
  elif [[ "$backup_type" == "rsync" ]]; then
    rsync -aA ${curr_backup_dir}/db/* ${ssh_user}@${remote_host}:${remote_curr_backup_dir}/db
    db_status=$?
  fi
  [[ $db_status != 0 ]] && backup_exception "Database backup error!" 9
  m_ok "Database backed up."

  if [[ "$backup_type" == "ftp" ]]; then
    m_normal "Backing up php config over ftp."
    lftp -u ${ftp_user},${ftp_pass} $remote_host -e "mirror -R ${www_dir}/config/ ${remote_curr_backup_dir}/config/; bye"
    config_php_status=$?
  elif [[ "$backup_type" == "rsync" ]]; then
    m_normal "Backing up php config over ftp."
    rsync -aA ${www_dir}/config/* ${ssh_user}@${remote_host}:${remote_curr_backup_dir}/config/
    config_php_status=$?
  fi
  [[ $config_php_status != 0 ]] && backup_exception "Php config backup error!" 11
  m_ok "Php config backed up."
  
  if [[ "$backup_type" == "ftp" ]]; then
    m_normal "Backing up www server config over ftp."
    lftp -u ${ftp_user},${ftp_pass} $remote_host -e "mirror -R ${web_server_conf} ${remote_curr_backup_dir}/www_config/; bye"
    config_www_status=$?
  elif [[ "$backup_type" == "rsync" ]]; then
    m_normal "Backing up php config over ftp."
    rsync -aA ${web_server_conf}/* ${ssh_user}@${remote_host}:${remote_curr_backup_dir}/www_config/
    config_www_status=$?
  fi
  [[ $config_www_status != 0 ]] && backup_exception "Web server config backup error!" 11
  m_ok "Web server config backed up."

  if [[ "$backup_type" == "ftp" ]]; then
    m_normal "Backing up storage over ftp."
    lftp -u ${ftp_user},${ftp_pass} $remote_host -e "mirror -R ${mount_snapshots}/ ${remote_curr_backup_dir}/storage/; bye"
    store_status=$?
  elif [[ "$backup_type" == "rsync" ]]; then
    m_normal "Backing up storage over ssh."
    rsync -aA ${curr_backup_dir}/storage/* ${ssh_user}@${remote_host}:${remote_curr_backup_dir}/storage/
    store_status=$?
  fi
  [[ $store_status != 0 ]] && backup_exception "Storage backup error!" 10
  m_ok "Storage backed up."

  m_ok "Backup ended sucessfully."
  announce_message_title+="success!"
  m_normal "Removing database dump"
  rm -rf "${curr_backup_dir}/db"
  [[ "$?" != 0 ]] && m_warn "Some problem during removing db backup source: ${curr_backup_dir}/db" 1
  m_normal "Unmountng snapshot"
  sudo /usr/bin/umount $mount_snapshot
  if [[ "$?" != 0 ]] then
    m_warn "Some problem during umounting: $mount_snapshot" 1
  else
    m_normal "Removing snapshot"
    sudo /usr/sbin/lvremove -y /dev/$vg_name/backup-$date
    [[ "$?" != 0 ]] && m_warn "Some problem during removing old snapshot /dev/$vg_name/backup-$date" 1 || m_ok "Done"
  fi
else
  m_warn "Backup not as task to do" 1
  announce_message_title+="not scheduled!"
fi
if [[ "$clean" -eq 1 ]]; then
  if [[ "$backup_type" == "ftp" ]]; then
    dates=( `lftp -u ${ftp_user},${ftp_pass} $remote_host -e "ls $remote_backup_dir/; bye" | awk '{print $9}' | sed 's/nextcloud-//g'` )
    [[ $? -ne 0 ]] && m_warn "Not obtained backups to clean!" 1 && break
  elif [[ "$backup_type" == "rsync" ]]; then
    dates=( `ssh ${ssh_user}@${remote_host} "ls $remote_backup_dir" | grep "nextcloud" | sed 's/nextcloud-//g'` )
    [[ $? -ne 0 ]] && m_warn "Not obtained backups to clean!" 1 && break
  fi
  sorted=( `echo ${dates[@]} | sed 's/ /\n/g' | sort -r -t '-' -k 1 -k 2 -k 3 ` )
  curr_ts=`date +%s`
  m_normal "Current backups: ${dates[@]}"
  for dat in ${sorted[@]:$backup_count}; do
    ts=`date -d $dat +%s`
    if [[ $(( $curr_ts - $ts )) -gt $(( 24 * 3600 * $min_days )) ]]; then
      m_ok "Outdated backup $dat. Removing $remote_backup_dir/nextcloud-$dat..."
      if [[ "$backup_type" == "ftp" ]]; then
        lftp -u ${ftp_user},${ftp_pass} $remote_host -e "set ftp:list-options -a; rm -rf $remote_backup_dir/nextcloud-$dat; bye;"
        status=$?
      elif [[ "$backup_type" == "rsync" ]]; then
        ssh ${ssh_user}@${remote_host} "rm -rf $remote_backup_dir/nextcloud-$dat"
        status=$?
      fi
      [[ "$status" -ne 0 ]] && m_warn "Some problem during removing: $remote_backup_dir/nextcloud-$dat" 1 || m_ok "Removed old backup: $remote_backup_dir/nextcloud-$dat" 1
    else 
      m_normal "Backup $dat not yet expired($min_days days)"
    fi
  done
else 
  m_warn "Cleaning disabled" 1
fi
announce_message+="Current backup directory: 
"
if [[ "$backup_type" == "ftp" ]]; then
  announce_message+=`lftp -u ${ftp_user},${ftp_pass} $remote_host -e "ls $remote_backup_dir/; bye;"`
elif [[ "$backup_type" == "rsync" ]]; then
  announce_message+=`ssh ${ssh_user}@${remote_host} "ls -l $remote_backup_dir"`
fi
if [[ $announce -eq 1 ]]; then
  send_message
fi
m_ok "Scheduling poweroff"
ssh ${ssh_user}@${remote_host} "sudo shutdown +5"
m_ok "Done. Hope you'll never need this..."
