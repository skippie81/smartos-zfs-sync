# smartos-zfs-sync

Backup remote smartos zfs volmes over ssh to local zfs volumes or to file(s).
Or backup local zfs volumes over ssh to a remote zfs volumes or file(s)

## Install

```
curl -kO https://raw.githubusercontent.com/skippie81/smartos-zfs-sync/master/zfs-sync.sh
chmod +x zfs-sync.sh
```

## Usage

Before you start the first backup.
- if using in default "send to zfs volume mode" the destination zfs volume should exits on the host that is receiving the zfs stream
- if using in "send to files mode" the destination directory should exist

If running with cleanup of old snapshot used for sending by the script (-c option). 
Only run this sync to one host as it will clean all previous snaps and if using for send to multiple hosts you might cleanup snap still needed to send next sync to differend host.
You might use cleanup function in combination with multiple backup locations in combination with the -p option and add a differend sanpshot prefix for ervery destination.
 

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

    -p <snapshot prefix>  :   snapshot prefix, the default is 'snap' resulting in a snapshot name: snap-YYYYmmddTHHMMSS

    -h                    :   displays this help message

    -Z                    :   include all zfs linked to vmadm LX or OS zones (if -Z the other ZFS list can be empty)
    [ZFS] ...             :   list of zfs to sync
```

example that would be run on the backup host and receives zfs volumes of all OS and LX zones and an extra zones/extra volme would be:

```
./zfs-sync.sh -r host.example.com -i my-private-key -d zones/backup/host.example.com -c -Z zones/extra
```

## Sheduling

When running in a smartos global zone there is a cron service, but the crontab will be empty afther a reboot.
Moving provided opt/custom/smf/enable-cront.xml, opt/custom/bin/setup-cron.sh and opt/custom/etc/cron/crontab.root to /opt/custom/...
will create a service (svc:smartos/cron-setup:default) that injects the /opt/local/etc/cront/crontab.root into the crontab after reboot.
Please modify crontab.root file as required.