#!/usr/bin/env bash

trap "exit 1" TERM
export SCRIPT_PID=$$

# print help
function do_help {
cat <<EOF
  backup and sync remote zfs volumes over ssh

  usage: $0 -r <host>|-s <host> [-i <keyfile>] [-P <port>] -p <destination zfs> [-Z] [-f] [-c] [-C <keep>] [-p <snapshot prefix>] [-h] [ZFS] [ZFS] ...
    -r <host>             :   receiving mode. the host this scripts runs on is the backup host and receives the zfs stream from <host>
    -s <host>             :   sending mode.   the host this scripts runs on is the source host and sends its zfs stream out to <host>

    -i <keyfile>          :   ssh key file for the remote host
    -P <port>             :   ssh port for the remote host

    -d <destination zfs>  :   the pool to receive the zfs stream (a zfs <destination pool>/<source zfs> wil be created for every source
                              in file mode this has to be and existing path to store the files

    -f                    :   file mode.      the backup host stores the zfs streams in compressed files. Initial full backup followed by incremental.
    -F                    :   full backup file mode.  the backup host stores zfs stream in compressed file. Always do full send to file.
    -c                    :   enable cleanup. removes older snapshots on the source volume (only keeps the latest backup snap)
    -C <nr_keep>          :   enable destination cleanup. keeps latest <nr_keep> and removes older snapshot on destinations ( only on zfs destinations )

    -p <snapshot prefix>  :   snapshot prefix, the default is \'snap\' resulting in a snapshot name: snap-YYYYmmddTHHMMSS

    -h                    :   displays this help message

    -Z                    :   include all zfs linked to vmadm LX or OS zones (if -Z the other ZFS list can be empty)
    [ZFS] ...             :   list of zfs to sync
EOF
if [[ "$@" != "" ]]
then
  echo ""
  echo "$@" >&2
  exit 1
fi
exit 0
}

# vars
snap_prefix=snap
ssh_port=22
ts=$(date +"%Y%m%dT%H%M%S")

mode=''
remote_host=''
remote_key=''
cleanup=false
to_file=false
force_initial=false
dest_cleanup=false

zfs_volumes=''
destination_pool=''

zone_backup=false

# read options
while getopts ":vhfFcZr:s:d:i:p:P:C:" opt
do
  case $opt in
    v)  set -x
        ;;
    r)  mode=receiving
        remote_host=$OPTARG
        ;;
    s)  mode=sending
        remote_host=$OPTARG
        ;;
    i)  remote_key=$OPTARG
        ;;
    d)  destination_pool=$OPTARG
        ;;
    f)  to_file=true
        ;;
    F)  to_file=true
        force_initial=true
        ;;
    c)  cleanup=true
        ;;
    C)  dest_cleanup=true
        dest_cleanup_keep=$OPTARG
        ;;
    h)  do_help
        ;;
    Z)  zone_backup=true
        ;;
    p)  snap_prefix=$OPTARG
        ;;
    P)  ssh_port=$OPTARG
        ;;
    \?) do_help "Invalid option: -$OPTARG"
        ;;
    :)  do_help "Option -$OPTARG requires value"
        ;;
  esac
done

# discard al the options from getopt, keep $@ for the zfs list
shift "$((OPTIND-1))"
zfs_volumes="$@"


# input checks
if [[ $mode == '' ]]; then do_help "mode -r or -s required"; fi
if [[ $destination_pool = '' ]]; then do_help "-p <destination pool> required"; fi
if ( $to_file ); then mode="${mode}-file"; fi
if [[ $remote_host == '' ]]; then do_help "remote host not given"; fi
if ! [[ $snap_prefix =~ ^[a-zA-Z0-9]+$ ]]; then do_help "snapshot prefix can only contain normal chars,numbers and _ or -"; fi
if ! [[ $ssh_port =~ ^[0-9]+$ ]]; then do_help "ssh port expect number"; fi

# removing leading / when destination is zfs pool
# the destination sould be <pool>/<vol>[[/vol]/...]
# if there is a leading / the zfs list en zfs list -r succeeds buth the zfs receive fails
if [[ $mode == 'sending' || $mode == 'receiving' ]]
then
  destination_pool=$(echo $destination_pool | sed -e 's/^\///g')
fi

# check when destination cleanup is enabled we are not running in send to file mode
# check if destination cleanup count is number > 1
if [[ $dest_cleanup == true ]]
then
  if [[ $to_file == true ]]
  then
    do_help "destination cleanup not possible in send to file mode"
  fi
  if ! [[ $dest_cleanup_keep =~ ^[0-9]+$ && $dest_cleanup_keep -gt 0 ]]
  then
    do_help "destination cleanup <nr_keep> needs number >= 1"
  fi
fi

# building the ssh command line
SSH_COMMAND="ssh"
if [[ $remote_key != '' ]]
then
  if [[ -f $remote_key ]]
  then
    SSH_COMMAND="$SSH_COMMAND -i $remote_key"
  else
    echo "Given key file not found!" >&2
    exit 1
  fi
fi
if [[ $ssh_port -ne 22 ]]
then
  SSH_COMMAND="$SSH_COMMAND -p $ssh_port"
fi
SSH_COMMAND="$SSH_COMMAND $remote_host"

# testing ssh connection
if ! ( $SSH_COMMAND ls 2> /dev/null 1>&2 )
then
  echo "ERROR: ssh connection - $SSH_COMMAND - not working"
  exit 1
fi

# functions

function check_source {
  case $mode in
    receiving*)   zfs_count=$($SSH_COMMAND zfs list -H $1 2> /dev/null | wc -l)
                  ;;
    sending*)     zfs_count=$(zfs list -H $1 2> /dev/null | wc -l)
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac

  if [[ $zfs_count -eq 0 ]]
  then
    printf "failed\n"
    kill -s TERM $SCRIPT_PID
  fi
}

function check_destination_pool {
  case $mode in
    receiving)        zfs list -H $1 1> /dev/null 2>&1
                      if [[ $? -ne  0 ]]
                      then
                        printf "destination pool not found\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    sending)          $SSH_COMMAND zfs list -H $1 1> /dev/null 2>&1
                      if [[ $? -ne  0 ]]
                      then
                        printf "destination pool not found\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    receiving-file)   if ! [[ -d $1 ]]
                      then
                        printf "destination directory not found\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    sending-file)     $SSH_COMMAND ls ${1}/ 1> /dev/null 2>&1
                      if [[ $? -ne 0 ]]
                      then
                        printf "destination directory not found\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    *)                kill -s TERM $SCRIPT_PID
                      ;;
  esac
}

function check_destination {
  case $mode in
    receiving)        zfs list -H $1 1> /dev/null 2>&1
                      return $?
                      ;;
    sending)          $SSH_COMMAND zfs list -H $1 1> /dev/null 2>&1
                      return $?
                      ;;
    receiving-file)   if [[ -d $destination_pool ]]
                      then
                        name=$(echo $1 | awk -F '/' '{print $NF}')
                        ls $destination_pool | grep $name 1> /dev/null 2>&1
                        return $?
                      else
                        printf "ERROR: Destination dir not found!\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    sending-file)     $SSH_COMMAND ls ${destination_pool}/ ]] 1> /dev/null 2>&1
                      if [[ $? -eq 0 ]]
                      then
                        name=$(echo $1 | awk -F '/' '{print $NF}')
                        $SSH_COMMAND ls $destination_pool 2> /dev/null | grep $name 1> /dev/null 2>&1
                        return $?
                      else
                        printf "ERROR: Destination dir not found!\n"
                        kill -s TERM $SCRIPT_PID
                      fi
                      ;;
    *)                kill -s TERM $SCRIPT_PID
                      ;;
  esac
}

function create_source_snap {
  volume_name=$1
  snapshot_name=$2
  case $mode in
    receiving*)   $SSH_COMMAND zfs snapshot ${volume_name}@${snapshot_name} 2> /dev/null
                  ;;
    sending*)     zfs snapshot ${volume_name}@${snapshot_name}
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac
  if [[ $? -ne 0 ]]
  then
    kill -s TERM $SCRIPT_PID
  fi
}

function initial_zfs_send {
  source_volume_name=$1
  snapshot_name=$2
  destination_volume_name=$3
  case $mode in
    receiving)        $SSH_COMMAND "zfs send ${source_volume_name}@${snapshot_name} | gzip -9" 2> /dev/null | \
                        gunzip -c - | zfs receive $destination_volume_name
                      ;;
    sending)          zfs send ${source_volume_name}@${snapshot_name} | gzip -9 | \
                        $SSH_COMMAND "gunzip -c - | zfs receive $destination_volume_name" 2> /dev/null
                      ;;
    receiving-file)   $SSH_COMMAND "zfs send ${source_volume_name}@${snapshot_name} | gzip -9" 2> /dev/null \
                        > "full_${destination_volume_name}@${snapshot_name}.zfs.gz"
                      ;;
    sending-file)     zfs send ${source_volume_name}@${snapshot_name} | gzip -9 | \
                        $SSH_COMMAND "dd of=full_${destination_volume_name}@${snapshot_name}.zfs.gz > /dev/null" 2> /dev/null 1>&2
                      ;;
    *)                kill -s TERM $SCRIPT_PID
                      ;;
  esac

  if [[ $? -ne 0 ]]
  then
    kill -s TERM $SCRIPT_PID
  fi
}

function list_source_snaps {
  case $mode in
    receiving*)   $SSH_COMMAND zfs list -r -t snapshot -H -o name $1 2> /dev/null
                  ;;
    sending*)     zfs list -r -t snapshot -H -o name $1
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac
}

function list_destination_snaps {
  case $mode in
    receiving)      zfs list -r -t snapshot -H -o name $1
                    ;;
    sending)        $SSH_COMMAND zfs list -r -t snapshot -H -o name $1 2> /dev/null
                    ;;
    receiving-file) ls -tr $destination_pool | grep $(echo $1 | awk -F '/' '{print $NF}') | \
                    sed -e 's/\.zfs\.gz$//g' | sed -e 's/^full_//g' | sed -e 's/^incremental_//g'
                    ;;
    sending-file)   $SSH_COMMAND ls -tr $destination_pool 2> /dev/null | grep $(echo $1 | awk -F '/' '{print $NF}') | \
                    sed -e 's/\.zfs\.gz$//g' | sed -e 's/^full_//g' | sed -e 's/^incremental_//g'
                    ;;
    *)              kill -s TERM $SCRIPT_PID
                    ;;
  esac
}

function incremental_zfs_send {
  source_volume_name=$1
  from_snap=$2
  to_snap=$3
  destination_volume_name=$4

  case $mode in
    receiving)      $SSH_COMMAND "zfs send -i ${source_volume_name}@${from_snap} ${source_volume_name}@${to_snap} | gzip -9" 2> /dev/null | \
                      gunzip -c - | zfs receive -F $destination_volume_name
                    ;;
    sending)        zfs send -i ${source_volume_name}@${from_snap} ${source_volume_name}@${to_snap} | gzip -9 | \
                      $SSH_COMMAND "gunzip -c - | zfs receive -F $destination_volume_name" 2> /dev/null
                    ;;
    receiving-file) $SSH_COMMAND "zfs send -i ${source_volume_name}@${from_snap} ${source_volume_name}@${to_snap} | gzip -9" 2> /dev/null \
                      1> "incremental_${destination_volume_name}@${snapshot_name}.zfs.gz"
                    ;;
    sending-file)   zfs send -i ${source_volume_name}@${from_snap} ${source_volume_name}@${to_snap} | gzip -9 | \
                      $SSH_COMMAND "dd of=incremental_${destination_volume_name}@${snapshot_name}.zfs.gz > /dev/null" 2> /dev/null
                    ;;
    *)              kill -s TERM $SCRIPT_PID
                    ;;
  esac
}

function cleanup_source_snap {
  case $mode in
    receiving*)   if ! ( $SSH_COMMAND zfs list -t snapshot $1 1> /dev/null 2>&1 ); then kill -s TERM $SCRIPT_PID; fi
                  $SSH_COMMAND zfs destroy $1 1> /dev/null 2>&1
                  ;;
    sending*)     if ! ( zfs list -t snapshot $1 1> /dev/null 2>&1 ); then kill -s TERM $SCRIPT_PID; fi
                  zfs destroy $1
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac
}

function cleanup_destination_snap {
  case $mode in
    receiving)    if ! ( zfs list -t snapshot $1 1> /dev/null 2>&1 ); then kill -s TERM $SCRIPT_PID; fi
                  zfs destroy $1
                  ;;
    sending)      if ! ( $SSH_COMMAND zfs list -t snapshot $1 1> /dev/null 2>&1 ); then kill -s TERM $SCRIPT_PID; fi
                  $SSH_COMMAND zfs destroy $1 1> /dev/null 2>&1
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac
}

function get_zone_zfs_list {
  case $mode in
    receiving*)   ( $SSH_COMMAND vmadm list -H -o zonepath type=OS 2> /dev/null | sed -e 's/^\///g'
                    $SSH_COMMAND vmadm list -H -o zonepath type=LX 2> /dev/null | sed -e 's/^\///g' ) | tr '\n' ' '
                  ;;
    sending*)     ( vmadm list -H -o zonepath type=OS | sed -e 's/^\///g'
                    vmadm list -H -o zonepath type=LX | sed -e 's/^\///g' ) | tr '\n' ' '
                  ;;
    *)            kill -s TERM $SCRIPT_PID
                  ;;
  esac
}

# check zfs list input

if ( $zone_backup )
then
  zfs_volumes="$zfs_volumes $(get_zone_zfs_list)"
fi

if [[ $zfs_volumes = '' ]]; then do_help "source zfs or -Z required"; fi

# main

printf "%-50s : %s\n" "Mode" $mode
printf "%-50s : %s\n" "Remote host" $remote_host
printf "%-50s : %s\n" "Remote key file" $remote_key
printf "%-47s  ... " "Checking destination"
check_destination_pool $destination_pool
printf "ok\n"

for zfs_volume in $zfs_volumes
do
  snap_name="${snap_prefix}-${ts}"
  zfs_destination="$destination_pool/$( echo $zfs_volume | awk -F '/' '{print $NF}' )"
  printf "%-50s : %s\n" "zfs source" $zfs_volume
  printf "%-50s : %s\n" "zfs destination" $zfs_destination
  printf "%-50s : %s\n" "new snapshot name" $snap_name

  printf "%-47s  ... " "checking zfs source volume"
  check_source $zfs_volume
  printf "ok\n"

  # if check_destination returns 1 the destination exists and an incremental backup is to be made
  # if not found we wil start an initial backup to a new zfs volume
  printf "%-47s  ... " "searching for destination volume/files"
  if ( check_destination $zfs_destination && ! ${force_initial} )
  then
    printf "found\n"
    printf "%-47s  ... " "listing snapshots on source"
    list_source_snaps $zfs_volume > /tmp/source_snaps
    printf "done\n"
    printf "%-47s  ... " "listing snapshots on destination"
    list_destination_snaps $zfs_destination > /tmp/destination_snaps
    printf "done\n"

    latest_common_snapshot=$(tail -1 /tmp/destination_snaps | sed -e 's/^.*\@//g' )

    printf "%-50s : %s\n" "latest snapshot on source for incremental sync" $latest_common_snapshot
    if ( grep $latest_common_snapshot /tmp/source_snaps 1> /dev/null 2>&1 )
    then
      printf "%-47s  ... " "creating snapshot on source"
      create_source_snap $zfs_volume $snap_name
      printf "done\n"
      printf "%-47s  ... " "sending incremental zfs stream"
      incremental_zfs_send $zfs_volume $latest_common_snapshot $snap_name $zfs_destination
      printf "done\n"

      printf "%-50s\n" "cleaning up old snapshots on source"
      for old_source_snap in $(grep "@${snap_prefix}" /tmp/source_snaps)
      do
        if [[ $old_source_snap =~ ^$zfs_volume\@$snap_prefix-[0-9]+T[0-9]+$  ]]
        then
          printf "%47s  ... " $old_source_snap
          if ( $cleanup )
          then
            cleanup_source_snap $old_source_snap
            printf "ok\n"
          else
            printf "skipping\n"
          fi
        fi
      done

      if [[ $dest_cleanup == true ]]
      then
        printf "%-47s  ... %s\n" "clearing old snapshtos on destination" "keep $dest_cleanup_keep"
        if [[ $(cat /tmp/destination_snaps | wc -l) -gt $dest_cleanup_keep ]]
        then
          for old_destination_snap in $( cat /tmp/destination_snaps | head -n $(( $( cat /tmp/destination_snaps | wc -l ) - dest_cleanup_keep )) )
          do
            printf "%47s ... " $old_destination_snap
            cleanup_destination_snap $old_destination_snap
            printf "ok\n"
          done
        else
          printf "%50s\n" "destinations only holds $(cat /tmp/destination_snaps | wc -l) previous snaps"
        fi
      fi

      rm -f /tmp/source_snaps
      rm -f /tmp/destination_snaps
    else
      printf "%-50s\n" "ERROR: latest snap on destination not found on source !!!"
      # no common snap but destination zfs exists should destroy and send initial backup
      # but not implemented as this might destory an zfs volume holding data
      exit 1
    fi
  else
    # will be creating an initial backup
    printf "%-47s  ... " "creating snapshot on source"
    create_source_snap $zfs_volume $snap_name
    printf "done\n"
    printf "%-47s  ... " "sending initial zfs stream"
    initial_zfs_send $zfs_volume $snap_name $zfs_destination
    printf "done\n"
  fi
done