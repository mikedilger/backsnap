#!/bin/env python3

# DEFINE VARIABLES -----------------------------------------------------------
__usage__="""Backsnap creates backup snapshots for gentoo-based linux installations.

* It copies a set of directories from one location to another
  * It uses rsync and only moves data that has changed
  * It uses network compression (optionally if the net is slow)
  * It uses nice and ionice so your system doesn't bog down

* It works across the network
  * You can either push or pull over ssh

* It is portage-aware, and doesn't back up system files that belong to
  gentoo packages if they haven't changed (can be overridden),
  Gentoo package files can be regenerated via a reinstall, so aren't
  strictly necessary to back up.

* It keeps many backup levels representing multiple snapshots in time
  * It uses the tower-of-hanoi schedule, so you have more recent ones and
    a few that go way back.
  * It uses hard linking to avoid duplication of files that haven't changed
    (see rsync --link-dest parameter).  So even if you have eight levels of
    backup, it won't take eight-times the original file system space because
    most files haven't changed (real world situations usually end up taking
    about 2x the original to hold 8 snapshots)

* The backups are full uncompressed filesystems matching the original
  * If we compressed them, we would lose the hardlink space saving.  It turns
    out for most real-world situations, the space gained by compressing
    backups separately is not as great as the space gained by not duplicating
    files across multiple backups if they haven't changed.   If you still
    want compression, either use a compressing file system at the backup
    destination, or zip up one of the snapshot level directories (I recommend
    lzip) for offline storage.
  * Because the backup is a valid unix directory copy, it can easily be
    live-mounted read-only, allowing users to access it at will and recover
    their own files without bothering the sysadmin.

You must first configure the backup destination.  Configuration settings are
stored at the destination:

  <dest>/.backsnap/config    - your configuration options
       SLOWNET=true|false      - on slow nets, wire compression is used
       MAXBACUKPS=n            - number of tower-of-hanoi levels (default 8)

  <dest>/.backsnap/excludes  - list of directories and files to exclude,
                               one path per line.

These files are created and managed automatically at the destination:

  <dest>/.backsnap/count     - sequentially increments, so backsnap can
                               figure out which level to do next
  <dest>/.backsnap/index     - saves a database of the gentoo files.

Usage:  backsnap [options] <dest> <src> [<src> ...]

    <dest>  - REQUIRED, you must specify a backup destination directory
    <src>   - REQUIRED, one or more source paths

     Either <dest> or <src> (but not both) may be a remote path in the
     form <hostname>:<path>.   In these cases, ssh is used underneath rsync.

    --dry-run
                  Just print what it would do, don't actually do it
    --slownet
                  Use network compression (default is to not use it)
    --rootdir rootdir
                  Root directory of the source (default is "/")
    --mtimeonly
                  Compare system files based on mtime only (skipping md5sum)
    --help
                  Print this usage
    --version
                  Print the version
    --credits
                  List authors and credits
    --incsystem
                  Include all system files in backups

  Do not run backsnap multiple times to back up multiple sources.  Rather
  list all the sources to be backed up on the command line for one
  invocation.  Otherwise it will increment the count, clear the destination
  (possibly erasing an older backup), and backup the data at a different
  backup level from the previous invocation.

  Backsnap must be run as root, and it must have root access to <dest>
  and <src>.  If this includes root access over the network via ssh,
  then ssh must not be impinged with password prompts. This can be
  achieved with ssh authorized_keys.  See ssh for details.

  Backups at the destination will be in directories named LEVELn/
  where n is the level.  These level numbers do NOT represent time order,
  but rather tower-of-hanoi depth.  To list the backups from oldest to
  newest, pass the -t option to ls.

  Example push usage from cron:
    59 15 * * *  root  /sbin/backsnap pluto:/backups/earth / /var

  Example pull usage from cron:
    45 2 * * 2   root  /sbin/backsnap /backups/earth earth:/ earth:/boot earth:/var

  Example read-only nfs mounting backups, backup server /etc/exports:
    /backups 192.168.1.0/24(ro,async,no_root_squash,no_subtree_check)

  Example read-only nfs mounting backups, client fstab:
    pluto:/backups/earth   /snapshots  nfs  proto=tcp,ro,noatime,soft,intr,nolock 0 0

# FROM OTHER PYTHON SCRIPT:
#   ./backup.py [-h|--help] [-r] [-t] [-b <tgz>] [-d <dir>]
#
#   -h --help : this help
#   -r : rebuild the whole indexes by scanning the /var/db/pkg files
#   -t : compare files based on mtime only (skip md5sum)
#   -b : build a tgz file. a-pkgs file will be created with the list of installed packages
#   -d : point of start for the analyze. Should be '/'
#
# This tool compares files you have installed with files we can find in installed gentoo packages. This comparison is based on md5sum, but you can skip it with the '-t' option. The result is put in /var/db/contents.dict, /var/db/files_to_backup and /var/db/pkgs.dict.
#
# With the -b option, you can directly create all the files necessary to rebuild your prefered gentoo distro.
# The <tgz> and <tgz>-pkgs files will allow you to rebuild the exact same enviroment.
#
#WARNING : adapt the global variable EXCLUDED_FILES to your needs.
#
"""
__credits__="""
by Michael Dilger <mike@mikedilger.com>
gentoo package file checking code from
    Vincent Delft <vincent_delft@yahoo.com>
rsync backup ideas taken from:
    http://www.mikerubel.org/computers/rsync_snapshots/
    http://www.sanitarium.net/golug/rsync_backups.html
tower of hanoi strategy from:
    http://en.wikipedia.org/wiki/Backup_rotation_scheme
"""
__author__="Michael Dilger"
__version__="0.4"
__last_modification__="15 February 2011"

# IMPORTS --------------------------------------------------------------------

import os.path,os
try:
  import cPickle as pickle
except:
  import pickle
import sys
import string
import fnmatch
import signal

# EXIT HANDLER AND TRAP SIGNALS ----------------------------------------------

ONEXIT=[]
def exitcode():
  global ONEXIT
  for code in ONEXIT:
    exec(code)
  sys.exit(1)

for i in [x for x in dir(signal) if x.startswith("SIG")]:
  try:
    print(i)
    signum = getattr(signal,i)
    signal.signal(signum,exitcode)
  except RuntimeError as m:
    print("Not trapping signal {0}".format(i))
  except ValueError:
    pass

# e.g.
  #ONEXIT.append('''# remove temp dir
  ##/bin/rm -rf --one-file-system --preserve-root $TMPDIR   # but this is bash
  #'''
  #);

# Verify that we are running as root -----------------------------------------

#if os.geteuid()!=0:
#  print("backsnap will only run as root.")
#  print(__usage__)
#  exitcode()

# DEBUG EXIT EARLY -----------------------------------------------------------

ONEXIT.append('print("hi")');
ONEXIT.append('print("bye")');
print("debugging, this script bailing out early.")
print(__usage__)
exitcode()

# DEFAULT CONFIGURATION ------------------------------------------------------

options = {"indstisset" : 0,
           "indst" : "",
           "insrclist" : "",
           "slownet" : False,
           "maxbackups" : 8,
           "dryrun" : 0,
           "rootdir" : "/",
           "mtimeonly" : False,
           "incsystem" : False}

# PARSE COMMAND LINE ---------------------------------------------------------

# FETCH REMOTE CONFIGURATION -------------------------------------------------

# BUILD GENTOO CONTENTS ------------------------------------------------------

# GENTOO
CONTENTS={}
PKGS={}
# XXXXX
EXCLUDED_FILES=['/usr/lib/python2*.pyc','/tmp/*','/dev/*','/proc/*','/var/db/pkg/*','/var/tmp/*','/var/cache/edb/*','/usr/src/linux-2.4*','/usr/portage/*','/photo/*','/music/*','/films/*','/didier/*']
TOTAL_SIZE=0
OUTPUT='/var/db/files_to_backup'
SPECIAL_CHAR=['-','\\','|','/']
SPECIAL_CHAR_POS=0

# perform_checksum(filename) returns the checksum.
# copied from /usr/lib/portage/bin/archive-conf
try:
        import fchksum
        def perform_checksum(filename): return fchksum.fmd5t(filename)
except ImportError:
        import md5
        def md5_to_hex(md5sum):
                hexform = ""
                for ix in xrange(len(md5sum)):
                        hexform = hexform + "%02x" % ord(md5sum[ix])
                return hexform.lower()

        def perform_checksum(filename):
                f = open(filename, 'rb')
                blocksize=32768
                data = f.read(blocksize)
                size = 0
                sum = md5.new()
                while data:
                        sum.update(data)
                        size = size + len(data)
                        data = f.read(blocksize)
                return (md5_to_hex(sum.digest()),size)




def output(data):
    global SPECIAL_CHAR, SPECIAL_CHAR_POS
    fid=open(OUTPUT,'a')
    fid.write("%s\n" % data)
    fid.close()
    sys.stdout.write('Analyzing directories : ' + SPECIAL_CHAR[SPECIAL_CHAR_POS] + '\r')
    sys.stdout.flush()
    SPECIAL_CHAR_POS+=1
    if SPECIAL_CHAR_POS==4: SPECIAL_CHAR_POS=0

def file_to_exclude(file):
    for excl in EXCLUDED_FILES:
        if fnmatch.fnmatch(file,excl):
            return 1
    return 0

def parse_dir(arg,dirname, files):
    global TOTAL_SIZE
    #if dir_to_exclude(dirname):
    #    return
    for file in files:
       curfile=os.path.join(dirname,file)
       if file_to_exclude(curfile):
           continue
       if os.path.isdir(curfile):
           pass
       elif os.path.islink(curfile):
           if not CONTENTS.has_key(curfile):
               output(curfile)
       elif os.path.isfile(curfile):
           size=os.path.getsize(curfile)
           if not CONTENTS.has_key(curfile):
               output(curfile)
               TOTAL_SIZE += size
           else:
               if arg['test_on_time']:
                   mtimereal=str(os.path.getmtime(curfile))
                   mtimestored=[res['mtime'] for res in CONTENTS[curfile]]
                   if mtimereal not in mtimestored:
                       output(curfile)
                       TOTAL_SIZE += size
               else:
                   md5stored = [string.lower(res['chksum']) for res in CONTENTS[curfile]]
                   md5real = string.lower(perform_checksum(curfile)[0])
                   if (md5real not in md5stored):
                       output(curfile)
                       TOTAL_SIZE += size
       else:
           output(curfile)

def analyze_dirs(dir,arg):
    if len(CONTENTS)==0:
        print("load CONTENTS first")
        return
    if dir[0]!="/":
        print("Only full path names are accepted!!!!")
        print("{0} is not valid".format(dir))
        print("May be you've forget the leading '/'")
        return
    print("Analyzing your directories")
    os.path.walk(dir,parse_dir,arg)
    print("Analyze finished")
    print("{0} bytes ".format(TOTAL_SIZE))


def parse_contents(file):
    global CONTENTS,PKGS
    package=file.split('/')[-2]
    file_content=open(file).readlines()
    for line in file_content:
        content=line.split()
        result={'pkg':package,'type':content[0]}
        if content[0]=='obj':
            result['chksum']=content[2]
            result['mtime']=content[3]
        if content[0]=='sym':
            result['link']=content[3]
        #some files belongs to several packages
        if CONTENTS.has_key(content[1]):
            CONTENTS[content[1]].append(result)
        else:
            CONTENTS[content[1]]=[result]
        PKGS[package]=1

def analyze_pkg(arg,dirname,files):
    for file in files:
        if file=='CONTENTS':
            print("."),
            parse_contents(os.path.join(dirname,file))

def update_contents():
    print("Analyzing your packages")
    os.path.walk('/var/db/pkg/',analyze_pkg,'')
    print("Analyze finished")
    print("{0} files indexed".format(len(CONTENTS)))

def load_contents():
    global CONTENTS
    print("Loading your index")
    fid=open('/var/db/contents.dict','r')
    CONTENTS=cPickle.load(fid)
    fid.close()
    print("Load finished")
    print("{0} files indexed".format(len(CONTENTS)))

def load_pkgs():
    global PKGS
    fid=open('/var/db/pkgs.dict','r')
    PKGS=cPickle.load(fid)
    fid.close()

def save():
    global CONTENTS,PKGS
    fid=open('/var/db/contents.dict','w')
    cPickle.dump(CONTENTS,fid)
    fid.close()
    fid=open('/var/db/pkgs.dict','w')
    cPickle.dump(PKGS,fid)
    fid.close()

def make_backup(tgz_file):
    os.system('tar -czvf %s -T %s' % (tgz_file,OUTPUT))
    pkgs=PKGS.keys()
    pkgs.sort()
    fid=open('%s-pkgs' % tgz_file,'w')
    for pkg in pkgs:
       fid.write('%s\n' % pkg)
    fid.close()


if __name__=="__main__":
    if len(sys.argv)>1:
        arg={'test_on_time':None}
        if "-h" in sys.argv or "--help" in sys.argv:
            print(__usage__)
            exitcode()
        if "-r" in sys.argv:
            update_contents()
            save()
        if "-t" in sys.argv:
            arg={'test_on_time':1}
        if "-d" in sys.argv:
            if "-r" not in sys.argv: load_contents()
            try:
                os.remove(OUTPUT)
            except OSError:
                pass
            dir=sys.argv[sys.argv.index("-d")+1]
            analyze_dirs(dir,arg)
        if "-b" in sys.argv:
            if "-r" not in sys.argv: load_pkgs()
            dir=sys.argv[sys.argv.index("-b")+1]
            make_backup(dir)
