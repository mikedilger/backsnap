Backsnap  (BACKup SNAPshots)
============================

FEATURES

* Backups traverse the network to a backup server.
* Snapshots are taken as often as you run the program, and rotated.
* Up to EIGHT full snapshots are kept, in a kind of exponential backoff
     (using the Towers of Hanoi strategy).  You always have the last, and
     the oldest one ranges from 65-128 days old.
* Even though (up to) 8 snapshots are kept, the storage required is much less
     than 8-fold of the original media, because hard links are used for files
     in common.
* The snapshots can be NFS mounted read-only, so recovery is simply a
     matter of rooting around in those directories and finding what you want.
* Uses only standard unix commands
* The backup can be either push or pull; one machine requires access to the
  other if backups are over the network.

FUTURE IDEAS

* squashfs compression... use this for a permanent offlining of backups.

------------------------------------------------------------------------------
DESTINATION DIRECTORY

First you need to setup a destination directory to receive backups.  You
should use separate destination directories for separate sources.  For
instance, Let's use /backups/zorro.  In this directory, create a
/backups/zorro/.backsnap/ directory and in this directory create your
/backups/zorro/.backsnap/config and /backups/zorro/.backsnap/excludes files.

config can be empty but can optionally contain these two variables:
  FASTNET=false
	If set to false, backsnap will compress network traffic.
	If set to true it will not
  MAXBACKUPS=8
	This is the maximum number of backup rotations to keep.

excludes is simply a list of directories and files to exclude from
backing up, one per line.  /backups/zorro/.backsnap/excludes must exist
so if you want to exclude nothing, make it an empty file.

Destination directories may either be on the local machine where
backsnap is run, or on a remote machine.  If they are on a remote machine,
that machine must have rsyncd and sshd running, and remote access by the
local backsnap user (usually without a password) via ssh must be allowed.
You can do this with an .ssh/authorized_keys file, e.g.:

   client# ssh-keygen
           [just hit RETURN when asked for a password]
   client# scp /root/.ssh/id_rsa.pub server:/root/.ssh/client.pub
   server# cat /root/.ssh/client.pub >> /root/.ssh/authorized_keys

Make sure there is enough space on the destination.  For the default 8
backup rotations spanning up to 128 days, you may need 1.5x to 3x of the
original space, but this of course depends upon your usage.

Choose a good filesystem.  The delete takes a long time on most filesystems.
XFS has fast deletes, and is recommended.  However reiserfs saves space
with small files, so that is also a fairly good choice.

Raid redundancy is probably not needed on the backup disk because backups are
already a redundant copy.   However if the disk fails you would lose the
multiple backup history.

------------------------------------------------------------------------------
BELOW THIS LINE IS OLD
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
  schedule them at different times or you will swamp the backup server.
