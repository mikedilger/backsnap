Backsnap  (BACKup SNAPshots)
============================

FEATURES

* Backups traverse the network to a backup server.
* Snapshots are taken daily.
* EIGHT full backups are kept, in a kind of exponential backoff (using the
     Towers of Hanoi strategy).  You always have yesterday, and the oldest
     one ranges from 65-128 days old.
* Even though 8 snapshots are kept, the storage required is much less than
     8-fold of the original media, because hard links are used for files in
     common.
* The snapshots are live NFS mounted read-only, so recovery is simply a
     matter of rooting around in those directories and finding what you want.
* Uses only standard unix commands


FUTURE IDEAS

* squashfs compression

------------------------------------------------------------------------------
INSTALLATION

A backsnap installation traverses a network.  You can't just install backsnap
on a system and be done.  You need to think about your layout, and make
changes on multiple machines.  We will talk about servers and clients.  A
server is a place where backups reside.  A client is machine that has data to
be backed up, and that needs to access historical data from time to time.


------------------------------------------------------------------------------
INSTALLATION:  SERVER

A backsnap server does not need any special backsnap software installed.
But it DOES need rsyncd, sshd, and nfs services (and in the future,
squashfs), and it needs each of these to be configured as described here.

X) Create an empty directory to store backups.  Make sure there is enough
   space.  For the default 8 backups spanning up to 128 days, without
   squashfs, you may need 1.5x to 3x of the original space, but this of
   course depends upon your usage.

X) Install sshd, and configure it to run at boot

X) Allow passwordless ssh access from root@eachclient to root@server.  I
   recommend using publickey crypto as follows:

   2a) client# ssh-keygen
	       [just hit RETURN when asked for a password]

   2b) client# scp /root/.ssh/id_rsa.pub server:/root/.ssh/client.pub

   2c) server# cat /root/.ssh/client.pub >> /root/.ssh/authorized_keys

X) Install rsyncd, and configure it to run at boot

X) Configure rsyncd

X) Install nfs, and configure it to run at boot

X) Add the following line to /etc/exports, substituting the proper values
   for your network, and the backup path


------------------------------------------------------------------------------
INSTALLATION:  CLIENT

Install a server first.

Backsnap consists of a script (/sbin/backsnap) and a config file
(/etc/backsnap/config).  Install these as follows:

   # cp -i ./sbin/backsnap /sbin/backsnap
   # chmod 0700 /sbin/backsnap
   # mkdir -p /etc/backsnap
   # chmod 0755 /etc/backsnap
   # cp -i ./etc/backsnap/config /etc/backsnap/config
   # chmod 0644 /etc/backsnap/config

Decide what directories you need to backup.  Backsnap will not
look beyond the file system that the directories specified reside on, so
if you need to include directories from multiple filesystems, you will
need to list each of them.  We will call these directories SOURCE_DIRS, and
in the config file (/etc/backsnap/config) you can define it, something like
this example:

	SOURCE_DIRS="/home /media"

Second, select a backup location for the backup data from this host.  This
INSTALL file will describe the setup for this one example host; if you need
to backup additional hosts, just do this configuration again for each of
them.  We recommend backing up to a separate host.  Will call the backup host
BACKUP_HOST,  and in the config file (/etc/backsnap/config) you can define
it, something like this example:

	BACKUP_HOST=backupmachine

The specific path on that machine where you want backups to reside is defined
in the next variable BACKUP_HOST_PATH.  Since this config file is for the one
machine being backed up, you may have a subdirectory to separate them from
other backups on the backupmachine, as we do in this example:

	BACKUP_HOST_PATH=/backups/mydesktop

Install the script "rotate" into $BACKUP_HOST:$BACKUP_HOST_PATH, as ".rotate",
as shown in this example:

	# scp rotate backupmachine:/backups/mydesktop/.rotate

Now we need to enable two access methods to the backup destination: rsync
daemon, and ssh.

Enable ssh by setting up an identity for root on the machine to be backed
up:

	mydesktop# ssh-keygen

Then copy the new public key to the authorized keys file for root on the
backup machine.  If that file already exists, add the key, don't clobber it
like this example does:

	# scp /root/.ssh/id_rsa.pub backupmachine:/root/.ssh/authorized_keys

Now you can test ssh this way

	# ssh backupmachine /bin/ls /

If that works without requiring a password, you're golden.

nfsmount....

cronjob...



