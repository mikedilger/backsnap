#!/bin/sh

echo "Warning:  This overwrites your config file!"
echo "press RETURN to continue"
read DUMMY

cp -i ./sbin/backsnap /sbin/backsnap
chmod 0700 /sbin/backsnap
mkdir -p /etc/backsnap
cp -i ./etc/backsnap/config /etc/backsnap/config

echo You are responsible for setting up Rsyncd on the backup server
echo You are responsible for NFS exporting from the backup server
echo You are responsible for NFS mounting from the backup server TWICE
echo You are responsible for setting up the cron job
