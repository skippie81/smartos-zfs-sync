#!/usr/bin/env bash

# crontab is running by default
# but after reboot there is no crontab file in the global zone
# this installs a crontab for user root in the global zone

cronfile='/opt/custom/etc/cron/crontab.root'

crontab $cronfile

