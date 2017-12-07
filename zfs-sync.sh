#!/usr/bin/env bash

#todo: fix file listings and sends in file mode

# print help
function do_help {
cat <<EOF
  backup and sync remote zfs volumes over ssh

  usage: $0 -r <host>|-s <host> [-i <keyfile>] -p <destination zfs> [-Z] [-f] [-c] [-p <snapshot prefix>] [-h] [ZFS] [ZFS] ...
    -r <host>             :   receiving mode. the host this scripts runs on is the backup host and receives the zfs stream from <host>
    -s <host>             :   sending mode.   the host this scripts runs on is the source host and sends its zfs stream out to <host>

    -i <keyfile>          :   ssh key file for the remote host

    -d <destination zfs>  :   the pool to receive the zfs stream (a zfs <destination pool>/<source zfs> wil be created for every source
                              in file mode this has to be and existing path to store the files

    -f                    :   file mode.      the backup host stores the zfs streams in compressed files
    -c                    :   enable cleanup. removes older snapshots on the source volume (only keeps the latest backup snap)

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
ts=$(date +"%Y%m%dT%H%M%S")

mode=''
remote_host=''
remote_key=''
cleanup=false
to_file=false

zfs_volumes=''
destination_pool=''

zone_backup=false

# read options
while getopts ":hfcZr:s:d:i:p:" opt
do
  case $opt in
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
    c)  cleanup=true
        ;;
    h)  do_help
        ;;
    Z)  zone_backup=true
        ;;
    p)  snap_prefix=$OPTARG
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


SSH_COMMAND="ssh $remote_host"
if [[ $remote_key != '' ]]
then
  if [[ -f $remote_key ]]
  then
    SSH_COMMAND="ssh -i $remote_key $remote_host"
  else
    echo "Given key file not found!" >&2
    exit 1
  fi
fi

# functions

function check_source {
  case $mode in
    receiving*)   zfs_count=$($SSH_COMMAND zfs list -H $1 2> /dev/null | wc -l)
                  ;;
    sending*)     zfs_count=$(zfs list -H $1 2> /dev/null | wc -l)
                  ;;
    *)            exit 1
                  ;;
  esac

  if [[ $zfs_count -eq 0 ]]
  then
    exit 1
  fi
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
                        #todo: returen 0 when incremental files is implementd
                        return 1
                      else
                        echo "ERROR: Destination dir not found!"
                        exit 1
                      fi
                      ;;
    sending-file)     $SSH_COMMAND [[ -d $destination_pool ]] 1> /dev/null 2>&1
                      #todo: return $? when incremental files is implemented
                      if [[ $? -eq 0 ]]
                      then
                        return 1
                      else
                        echo "ERROR: Destination dir not found!"
                        exit 1
                      fi
                      ;;
    *)                exit 1
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
    *)            exit 1
                  ;;
  esac
  if [[ $? -ne 0 ]]
  then
    exit $?
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
                        > "${destination_volume_name}_${snapshot_name}.zfs.gz"
                      ;;
    sending-file)     zfs send ${source_volume_name}@${snapshot_name} | gzip -9 | \
                        $SSH_COMMAND "tee ${destination_volume_name}_${snapshot_name}.zfs.gz > /dev/null" 2> /dev/null
                      ;;
    *)                exit 1
                      ;;
  esac

  if [[ $? -ne 0 ]]
  then
    exit $?
  fi
}

function list_source_snaps {
  case $mode in
    receiving*)   $SSH_COMMAND zfs list -r -t snapshot -H -o name $1 2> /dev/null
                  ;;
    sending*)     zfs list -r -t snapshot -H -o name $1
                  ;;
    *)            exit 1
                  ;;
  esac
}

function list_destination_snaps {
  case $mode in
    receiving)      zfs list -r -t snapshot -H -o name $1
                    ;;
    sending)        $SSH_COMMAND zfs list -r -t snapshot -H -o name $1 2> /dev/null
                    ;;
    receiving-file) echo ""
                    #todo: only full send in file mode at this moment, should implemt incremntal files
                    #ls | grep $1 | sed -e "s/^"$1"_//g" | sed -e "\.zfs\.gz$//g"
                    ;;
    sending-file)   echo ""
                    #todo: only full send in file mode at this moment, should implemt incremntal files
                    #$SSH_COMMAND "ls $1 | grep $1" | sed -e "s/^"$1"_//g" | sed -e "\.zfs\.gz$//g"
                    ;;
    *)              exit 1
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
                      1> "${destination_volume_name}_${snapshot_name}.zfs.gz"
                    ;;
    sending-file)   zfs send -i ${source_volume_name}@${from_snap} ${source_volume_name}@${to_snap} | gzip -9 | \
                      $SSH_COMMAND "tee ${destination_volume_name}_${snapshot_name}.zfs.gz > /dev/null" 2> /dev/null
                    ;;
    *)              exit 1
                    ;;
  esac
}

function cleanup_source_snap {
  case $mode in
    receiving)    if ! ( $SSH_COMMAND zfs list -t snapshot $1 1> /dev/null 2>&1 ); then exit 1; fi
                  $SSH_COMMAND zfs destroy $1 1> /dev/null 2>&1
                  ;;
    sending)      if ! ( zfs -t snapshot $1 1> /dev/null 2>&1 ); then exit 1; fi
                  zfs destroy $i
                  ;;
    *)            exit 1
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
    *)            exit 1
                  ;;
  esac
}

# check zfs list input

if ( $zone_backup )
then
  zfs_volumes="$zfs_volumes $(get_zone_zfs_list)"
fi

if [[ $zfs_volumes = '' ]]; then do_help "source zfs required"; fi

# main

printf "%(%Y%m%d %H:%M:%S)T start zfs sync\n"
printf "%-50s : %s\n" "Mode" $mode
printf "%-50s : %s\n" "Remote host" $remote_host
printf "%-50s : %s\n" "Remote key file" $remote_key

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
  if ( check_destination $zfs_destination )
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
      rm -f /tmp/source_snaps
      rm -f /tmp/destination_snaps
    else
      printf "%-50s" "ERROR: latest snap on destination not found on source !!!\n"
      # no common snap but destination zfs exists should destroy and send initial backup
      # but not implemented as this might destory an zfs volume holding data
      exit 1
    fi
  else
    printf "not found\n"
    # will be creating an initial backup
    printf "%-47s  ... " "creating snapshot on source"
    create_source_snap $zfs_volume $snap_name
    printf "done\n"
    printf "%-47s  ... " "sending initial zfs stream"
    initial_zfs_send $zfs_volume $snap_name $zfs_destination
    printf "done\n"
  fi
done