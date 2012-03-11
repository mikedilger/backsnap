#!/bin/sh

# Backsnap:   Pushes or pulls a backup snapshot to/from a directory to backup
#
# This file is part of Backsnap.
#
# This code is Copyright (c) Optimal Computing Limited of New Zealand, 2011.
# mike@optimalcomputing.co.nz  Michael Dilger
#
# Backsnap is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Backsnap is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


#VERSION=0.3.1
#
# Usage:  backsnap <dest> <src> [<src> ...]
#
#     <dest>  - REQUIRED, you must specify a backup destination directory
#     <src>   - REQUIRED, one or more source paths
#
#     Either <dest> or <src> (but not both) may be a remote path in the
#     form <hostname>:<path>.   In these cases, ssh is used.
#
# NOTE ON VERSION 0.3.1:
# Excludes file gone; now using rsync filter file
#
# NOTE ON VERSION 0.3:
# Configiration data must be in <dest>/.backsnap in these files:
#    <dest>/.backsnap/config
#    <dest>/.backsnap/filter
#    <dest>/.backsnap/count
# Configuration information in /etc/backsnap is no longer relevant.  That
# is because backsnap operation is no longer conceived to be per-system
# but rather per-destination.
#
# NOTE ON NEW VERSION 0.1:
# After backsnap 'rotates' previous backups, it will clear the destination.
# Then it will backup each <src> into this destination.  Then it will update
# the count.   If you run a subsequent backsnap command to backup more
# data to this destination IT WILL CLEAR IT FIRST.   So make it all one
# command.  The --nocount and --noclear options have been removed, and
# backsnap will fail to run if it encounters an option it doesn't understand.
#
# backsnap must be run as root, and must have root access via ssh to the
#   remote system, without password prompts (it is recommended to use
#   ssh authorized_keys.  See ssh for details).
#
# Snapshots are rotated daily on a tower-of-hanoi schedule.  To see the
#   backups in date order, use the -t option to ls.
#
# Example usage from cron:
#   59 15 * * *    root   /sbin/backsnap pluto:/ /backups/pluto/
#   59 18 * * *    root   /sbin/backsnap saturn:/ /backups/saturn/
#
# Snapshots are useful nfs mounted read-only, so users can recover their
#   files with a minimum of fuss.
# Sample /etc/exports line:
#   /backups 192.168.1.0/24(ro,async,no_root_squash,no_subtree_check)
# Sample /etc/fstab line:
#   backuphost:/backups/saturn   /snapshots  nfs  proto=tcp,ro,noatime,soft,intr,nolock 0 0
#
# Credits:
#   Written by Mike Dilger
#   Derived from discussions on these pages:
#     http://www.mikerubel.org/computers/rsync_snapshots/
#     http://www.sanitarium.net/golug/rsync_backups.html
#     http://en.wikipedia.org/wiki/Backup_rotation_scheme
#
#-------------------------------------------------------------------------
# Avoid accidental use of $PATH
unset PATH
PATH=/bin:/usr/bin:/usr/local/bin

# Find programs
PROGS="touch mktemp id rm expr mkdir dirname awk rsync"
for p in ${PROGS} ; do
  hash ${p} 2>&- || { echo >&2 "Cannot find ${p}.  Aborting."; exit 1; }
done

#-------------------------------------------------------------------------
# Verify we are running as root
THISUID=`id -u`
if [ $THISUID -ne 0 ] ; then
    /bin/echo "This script will only run as root."
    exit 1
fi

#-------------------------------------------------------------------------
# Trap to clean up temporary files

declare -a on_exit_items

function on_exit()
{
    for i in "${on_exit_items[@]}"
    do
        /bin/echo "on_exit: $i"
        eval $i
    done
}

function add_on_exit()
{
    local n=${#on_exit_items[*]}
    on_exit_items[$n]="$*"
    if [[ $n -eq 0 ]]; then
        /bin/echo "Setting trap"
        trap on_exit EXIT
    fi
}

#-------------------------------------------------------------------------

function usage {
    /bin/echo "Usage:  backsnap [options] <dst> <src> [<src>]"
    /bin/echo "  --version    Print the version"
    /bin/echo "  --fastnet    Don't use network compression"
    /bin/echo "  --dry-run    Just print what it would do, don't actually"
}

#-------------------------------------------------------------------------
# Parse/validate the parameters

INDSTISSET=0
INDST=
INSRCLIST=
LNICE=
RNICE=
LIONICE=
RIONICE=
for PARAM in $@; do

    case $PARAM in
        -*) true;
            case $PARAM in
                --version)
                    /bin/echo "Version $VERSION"
                    exit 0
                    ;;
                --fastnet)
                    FASTNET=true
                    ;;
                --maxbackups)
                    shift
                    MAXBACKUPS=$1
                    ;;
                --dry-run)
                    TESTING="/bin/echo"
                    ;;
                --local-nice)
                    LNICE="nice"
                    ;;
                --remote-nice)
                    RNICE="nice"
                    ;;
                --local-ionice)
                    hash ionice 2>&- || { echo >&2 "Cannot find ionice.  Aborting."; exit 1; }
                    LIONICE="ionice -c 3"
                    ;;
                --remote-ionice)
                    shift
                    RIONICE="ionice -c 3"
                    ;;
                -*)
                    /bin/echo "Option $PARAM is not recognized.  Bailing out."
                    usage
                    exit 1
                    ;;
            esac
            ;;
        *)
            if [ $INDSTISSET -eq 1 ] ; then
                INSRCLIST="$INSRCLIST $PARAM"
            else
                INDST=$PARAM
                INDSTISSET=1
            fi
            ;;
    esac
    shift

done

if [ "x$INSRCLIST" = x ] ; then
    /bin/echo "You must specify <dest> and <src>"
    usage
    exit 1
fi
if [ "x$INDST" = x ] ; then
    /bin/echo "You must specify <dest> and <src>"
    usage
fi

# Debug
#/bin/echo "SOURCE      = $INSRCLIST"
#/bin/echo "DESTINATION = $INDST"
#exit 1

# Verify no more than one is remote
REMOTE=0
# note: multiple INSRCLIST is still just 1 line, so this is ok:
REMOTESRC=`/bin/echo $INSRCLIST | /bin/grep : | /usr/bin/wc -l`
REMOTE=`expr $REMOTE + $REMOTESRC`
REMOTEDST=`/bin/echo $INDST | /bin/grep : | /usr/bin/wc -l`
REMOTE=`expr $REMOTE + $REMOTEDST`
if [ $REMOTE -gt 1 ] ; then
    echo "At most one of <src> or <dst> may be local"
    exit 1
fi

# Parse INDST
if [ $REMOTEDST -ne 0 ] ; then
    DSTHOST=`/bin/echo ${INDST} | awk -F: '{print $1}'`
    DSTPATH=`/bin/echo ${INDST} | awk -F: '{print $2}'`
    DSTACCESS="/usr/bin/ssh ${DSTHOST}"
else
    DSTHOST=
    DSTPATH=${INDST}
    DSTACCESS=
fi

#-------------------------------------------------------------------------
# Deal with possibly remote config and filter files

TMPDIR=`mktemp -d`
if [ x$TMPDIR = x ] ; then
  echo Failed to make temp directory.
  exit 1
fi
add_on_exit rm -rf --preserve-root "$TMPDIR"

if [ $REMOTEDST -ne 0 ] ; then
    ${LNICE} ${LIONICE} /usr/bin/scp $DSTHOST:$DSTPATH/.backsnap/config $DSTHOST:$DSTPATH/.backsnap/filter ${TMPDIR}
    if [ $? -ne 0 ] ; then
        /bin/echo "Failed to find $DSTHOST:$DSTPATH/.backsnap/config or $DSTHOST:$DSTPATH/.backsnap/filter"
        exit 1
    fi
else
    /bin/cp $DSTPATH/.backsnap/config $DSTPATH/.backsnap/filter $TMPDIR
    if [ $? -ne 0 ] ; then
        /bin/echo "Failed to find $DSTPATH/.backsnap/config or $DSTPATH/.backsnap/filter"
        exit 1
    fi
fi
source $TMPDIR/config
FILTER_FILE=$TMPDIR/filter

#-------------------------------------------------------------------------
# Setup a few general parameters

if [ x$FASTNET = xtrue ] ; then PERFOPTS=-W; else PERFOPTS=-z; fi
if [ $REMOTE -eq 0 ] ; then
    # Not remote, no compressionk
    PERFOPTS=-W;
    export RSYNC_RSH=""
else
    # Set the RSYNC_RSH variable to be sure we are using SSH, and set some
    # parameters for that
    #    -c arcfour:          weak fast encryption
    #    -o Compression=no:   rsync already compresses, ssh doesn't need to
    #    -x:                  Turn off X tunnelling (shouldn't be on anyways)
    # export RSYNC_RSH="/usr/bin/ssh -c arcfour -o Compression=no -x"
    export RSYNC_RSH="${RNICE} ${RIONICE} /usr/bin/ssh -c arcfour -o Compression=no -x"
fi

#---------------------------------------------------------------------
# DSTPATH must exist

${DSTACCESS} /usr/bin/test -d ${DSTPATH}
if [ $? -ne 0 ] ; then
  /bin/echo "${INDST} does not exist."
  exit 1
fi

#---------------------------------------------------------------------
# Determine the rotation target

if [ z"$MAXBACKUPS" = z ] ; then MAXBACKUPS=8; fi

COUNT=`${DSTACCESS} /bin/cat ${DSTPATH}/.backsnap/count 2>/dev/null`
if [ x$COUNT = x ] ; then COUNT=0; fi

# safety:
COUNTWORDS=`/bin/echo $COUNT | /usr/bin/wc -w`
if [ $COUNTWORDS -ne 1 ] ; then
    /bin/echo "count at destination does not contain a single number"
    exit 1
fi
# COUNT=`/bin/date +%j`  # <-- daily method has problem if days are skipped

if [ $COUNT -eq 0 ] ; then
  # Pre-tower strategy, do last level once
  TARGET='LEVEL'$MAXBACKUPS
else
  # Tower of hanoi strategy
  MODULUS=1
  for (( LVL=1 ; $LVL < $MAXBACKUPS ; LVL=$LVL+1 )) ; do
    MODULUS=`/usr/bin/expr $MODULUS \* 2`
    MOD=`/usr/bin/expr $COUNT % $MODULUS`
    if [ $MOD -ne 0 ] ; then break; fi
  done
  # Worst case backup period is (2^(n-2)+1) backups
  # Best case backup period is (2^(n-1)) backups
  TARGET='LEVEL'$LVL
fi

if [ x$TARGET = x ] ; then
    /bin/echo "TARGET did not get set."
    /bin/echo "Safety check stopping script"
    exit 1
fi

#---------------------------------------------------------------------
# Validate access for first SRC (before deleting target)

# If multiple src, just use the first for validation:
INSRC=`echo $INSRCLIST | awk '{ print $1; }'`

if [ $REMOTESRC -ne 0 ] ; then
    SRCPATH=`/bin/echo ${INSRC} | awk -F: '{print $2}'`
else
    SRCPATH=${INSRC}
fi
SRCDIR=`dirname $SRCPATH`

# NOTE: we use ${INDST}/${TARGET} instead of ${INDST}/${TARGET}/${SRCDIR}
# because we know it exists, no need to create it, tests our permissions,
# and --dry-run doesn't write anything anyways.

# not recursive, dirs copys as dir not going in,
# --links, --perms --times --group --owner --devices --specials all from -a

${TESTING} ${LNICE} ${LIONICE} rsync \
    --links --perms --times --group --owner \
    --devices --specials --one-file-system --sparse \
    --numeric-ids ${PERFOPTS} --dirs \
    --dry-run \
    ${INSRC} ${INDST}/${TARGET}
exitval=$?
# Errors which are acceptible for proceeding: 0,6,21,23,24,25
case $exitval in
    (0|6|21|23|24|25) ;;
    *)
        /bin/echo "Dry-run failed.  Bailing out."
        exit 1
        ;;
esac

# Unset these validation variables
SRCPATH=
SRCDIR=

#---------------------------------------------------------------------
# Delete target

SAFETYCOUNT=`/bin/echo ${DSTPATH} | /usr/bin/wc -m`
if [ $SAFETYCOUNT -lt 3 ] ; then
    /bin/echo "Destination Path  < 3 characters"
    /bin/echo "Safety check stopping script"
    exit 1
fi

/bin/echo
/bin/echo "Clearing destination ${DSTPATH}/${TARGET} ..."
${TESTING} ${DSTACCESS} ${RNICE} ${RIONICE} rm -rf --preserve-root ${DSTPATH}/${TARGET}

#---------------------------------------------------------------------
# Determine the newest backup (for link-dest), newest that is not target.

LINKTARG=
NEWESTLIST=`${DSTACCESS} /bin/ls -1t ${DSTPATH}`
for TT in $NEWESTLIST ; do
    if [ x$TT != x$TARGET ] ; then
        LINKTARG="${DSTPATH}/$TT"
        break;
    fi
done

#-------------------------------------------------------------------------
# Loop for each src specified
for INSRC in $INSRCLIST; do

    /bin/echo

    # Parse INSRC
    if [ $REMOTESRC -ne 0 ] ; then
        SRCPATH=`/bin/echo ${INSRC} | awk -F: '{print $2}'`
    else
        SRCPATH=${INSRC}
    fi
    SRCDIR=`dirname $SRCPATH`

    #---------------------------------------------------------------------
    # If dest directory exists, clear it
    /bin/echo "Clearing destination ${DSTPATH}/${TARGET}${SRCPATH} ..."
    ${TESTING} ${DSTACCESS} ${RNICE} ${RIONICE} rm -rf --preserve-root ${DSTPATH}/${TARGET}${SRCPATH}

    #---------------------------------------------------------------------
    # Make a directory for the new backup
    /bin/echo "Making destination ${DSTPATH}/${TARGET}${SRCDIR} ..."
    ${TESTING} ${DSTACCESS} mkdir -p ${DSTPATH}/${TARGET}${SRCDIR} || exit 2;

    #---------------------------------------------------------------------
    # Take the snapshot

    # rsync the source directory into ${TARGET}, using ${NEWEST} as the link
    # destination (that is, if the file is already in ${NEWEST}, hardlink
    # instead of copying anew)
    # -a        archive flags
    # -x        don't cross filesystem boundaries
    # -S                    handle sparse files as sparse files
    # --password-file       password for ssh access
    # --exclude-from        skip these directories
    # --numeric-ids         important if UIDs/GIDs are not in sync
    # --link-dest           If exists here, hardlink instead of creating anew
    #
    # These are not used because we start into a fresh directory:
    # --delete              delete first (may not matter if target empty)
    # --delete-excluded     delete newly excluded directories on taget
    #

    /bin/echo "Taking snapshot of ${INSRC}  ..."

    if [ x$LINKTARG != x ] ; then
        LINKPARAM=--link-dest=${LINKTARG}${SRCPATH}
    else
        LINKPARAM=
    fi

    ${TESTING} ${LNICE} ${LIONICE} rsync --archive \
        --one-file-system --sparse \
        --filter=._${FILTER_FILE} \
        --numeric-ids ${LINKPARAM} ${PERFOPTS} \
        ${INSRC} ${INDST}/${TARGET}${SRCDIR}
    exitval=$?
    # Errors which are acceptible for proceeding: 0,6,21,23,24,25
    case $exitval in
        (0|6|21|23|24|25) ;;
        *)
            /bin/echo "Bailing out."
            exit 1
            ;;
    esac

done

# Mark target as new, after we are finished with it
${TESTING} ${DSTACCESS} touch ${DSTPATH}/${TARGET}

# ------------------------------------------------------------------
# Update the count only after we are done (if it was only partial, the
# count will be the same, so the next backup will just try again in the
# same slot)

COUNT=`/usr/bin/expr $COUNT + 1`
if [ $REMOTEDST -ne 0 ] ; then
    ${TESTING} ${DSTACCESS} "/bin/echo $COUNT > ${DSTPATH}/.backsnap/count"
else
    if [ x$TESTING = x ] ; then
        /bin/echo $COUNT > ${DSTPATH}/.backsnap/count
    fi
fi

exit 0
