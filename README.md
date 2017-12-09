# smartos-zfs-sync

Backup remote smartos zfs volmes over ssh to local zfs volumes or to file(s).
Or backup local zfs volumes over ssh to a remote zfs volumes or file(s)

## Install

```
curl -kO https://raw.githubusercontent.com/skippie81/smartos-zfs-sync/master/zfs-sync.sh
chmod +x zfs-sync.sh
```

## Usage

```
  backup and sync remote zfs volumes over ssh

  usage: zfs-sync.sh -r <host>|-s <host> [-i <keyfile>] [-P <port>] -p <destination zfs> [-Z] [-f] [-c] [-p <snapshot prefix>] [-h] [ZFS] [ZFS] ...
    -r <host>             :   receiving mode. the host this scripts runs on is the backup host and receives the zfs stream from <host>
    -s <host>             :   sending mode.   the host this scripts runs on is the source host and sends its zfs stream out to <host>

    -i <keyfile>          :   ssh key file for the remote host
    -P <port>             :   ssh port for the remote host

    -d <destination zfs>  :   the pool to receive the zfs stream (a zfs <destination pool>/<source zfs> wil be created for every source
                              in file mode this has to be and existing path to store the files

    -f                    :   file mode.      the backup host stores the zfs streams in compressed files
    -c                    :   enable cleanup. removes older snapshots on the source volume (only keeps the latest backup snap)

    -p <snapshot prefix>  :   snapshot prefix, the default is \'snap\' resulting in a snapshot name: snap-YYYYmmddTHHMMSS

    -h                    :   displays this help message

    -Z                    :   include all zfs linked to vmadm LX or OS zones (if -Z the other ZFS list can be empty)
    [ZFS] ...             :   list of zfs to sync
```