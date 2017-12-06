# smartos-zfs-backup-sync

Backup remote smartos zfs volumes and syncronize

## Usage

```
  usage: ./zfs-syn.sh -r <host>|-s <host> [-i <keyfile>] -p <destination zfs> [-f] [-c] [-h] [ZFS] [ZFS] ...
    -r <host>             :   receiving mode. the host this scripts runs on is the backup host and receives the zfs stream from <host>
    -s <host>             :   sending mode.   the host this scripts runs on is the source host and sends its zfs stream out to <host>

    -i <keyfile>          :   ssh key file for the remote host

    -d <destination zfs>  :   the pool to receive the zfs stream (a zfs <destination pool>/<source zfs> wil be created for every source
                              in file mode this has to be and existing path to store the files

    -f                    :   file mode.      the backup host stores the zfs streams in compressed files
    -c                    :   enable cleanup. removes older snapshots on the source volume (only keeps the latest backup snap)

    -h                    :   displays this help message

    [ZFS] ...             :   list of zfs to sync

```

## Warn

The -f option for sending to files only supports full zfs send no incremental sends implemented yet.