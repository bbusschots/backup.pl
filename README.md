# backup.pl
A simple backup script for backing up data on one Linux/Unix/OS X server from another over SSH.

This script isn't trying to be the ultimate best backup script ever, it's just a
simple script that I use that I thought others might find useful, either as-is,
or as a starting point for modification into a custom script of your own. If
you need something powerful and flexible that keeps an arbitrary number of
versions for an arbitrary amount of time, this is not the script for you. You
might find rsnapshot a useful alternative.

This script keeps 7 rolling backups - one for every day of the week. It keeps
those backups in folders called `Mon`, `Tue`, `Wed`, and so on. If you run the
script on a Monday, your backup will go into the `Mon` folder, if do it on a
Tuesday, it'll go into the `Tue` folder, and so on. If you don't want a 7 day 
rolling backup, you'll either have to alter this script, or use something else.

At the moment this script can perform an arbitrary number of the following
operations on an arbitrary number of servers:
1. Create and download a MySQL dump of all databases in an instance of MySQL
   running locally on the server. (only one instance of this operation per
   server)
2. Create `.tar.gz` archives of folders and download them.
3. Clone folders using `rsync` over ssh.
4. Create SVN dumps from folders of SVN repositories and download them.

This tells you what matters to me - MySQL datatabases, files, and SVN 
repositories. If you need a different type of backup, you'll either need to
alter this script, or use something else.

## Requirements
Assuming this limited feature set meets your requirements, the script is very
east to set up and use.

Firstly, the serer that will be hosting the script, and your backup data, needs
to meet the following simple requirements:
1. Be POSIX compliant (Linux, Unix, OS X, or something like Cygwin on
   Windows)
2. SSH and SCP need to be installed, and, optionally, rsync with SSH support.
3. Perl needs to be installed, along with the following Perl modules (all of 
   which are available through CPAN):
   * `Carp`
   * `Getopt::Std`
   * `JSON`
   * `IO::CaptureOutput`
   * `String::ShellQuote`

The servers being backed up need to meet the following requirements:
1. Be POSIX compliant
2. Have SSH installed and running, and be accessible over SSH from the computer
   running the backup script. SSH keys must also be in place so the server
   performing the backups can log in to the server being backed up without a
   password.
3. Have a folder available for use by the script as a staging area. This staging
   area will need to be large enough to hold coppies of all the files generated
   by the backup script.
4. Each available backup type also has additional requirments:
   * MySQL dump requirments:
     1. The MySQL server must be running locally on the server being backed up.
     2. The `mysqldump` commandline tool must be installed
   * TAR backups:
     1. The `tar` commandline tool must be installed, and must have gzip support.
   * rsync backups:
     1. The destination server has to support rsync over ssh.
   * SVN backups:
     1. the `svnadmin` commandline took must be installed.

## Using the Script
The backup script can be run without arguments to see the list of required
arguments and optional flags.

The `-c` flag is required, and must be used to specify the path to a config file
that instructs the backup script what down backup from where to where. (More on
this config file below.)

The optional `-v` flag can be used to request more verbose output.

The optional `-d` flag is used to enter debug mode, and it implies `-v`. In
debug mode the script will not actually execute any commands, instead, it will
print out the commands it would execute if it were run without the `-d` flag.

The script is designed to be run via cron, using an entry that looks something
like:

	0 4 * * * /var/backup/backup.pl -c /var/backup/my_config.json
	
The example above will run the backup script at 4am each day using the config
file `/var/backup/my_config.json`.

## The Config File

The config file is in JSON format. No point in re-inventing the wheel after all!

A sample config file is included in this project, it should be pretty 
self-explanatory.

It is important to note that all paths to folders *MUST* end in a trialing `/`.

The JSON file represents a hash table indexed by two keys - `localPaths`, and
`servers`. 

`localPaths` is itself a hash table which contains keys for spcifying
the local path to executables like `ssh` and `scp`, and the key `backupBaseDir`
for specifying the local folder in which the backups should be stored. Inside
this local folder a folder will be created for every day of the week, and inside
those folders a folder will be created for every server being backed up.

`servers` is an array of hash tables, one for each server to be backed up.

Each server hashref requries the following keys:
* `fqdn` - the fully qualified domain name of the sever
* `sshUsername` - the username to connect to the server with via SSH
* `remotePaths` - a hash table of needed paths on the remote server. For now,
  only one remote path is needed `stagingDir`, specifyign the folder on the
  remote server which the script will use to stage backup files before
  downloading them.

Each server hashref then requires one or more of the following keys, specifying
a type of backup:
* `backup_MySQL` - a hash table contianing the information needed to perform
  a MySQL dump. (See the sample config file for details.)
* `backup_tar` - a hash table containing the information needed to create and
  download `.tar.gz` files from one or more folders on the server. (See the 
  sample config file for details.)
* `backup_rsync` - a hash table containing the information needed rsync one or 
  more folders on the server. (See the sample config file for details.)
* `backup_svndump` - a hash table containing the information needed to create
  and download `.svndump` files for one or more folderes of SVN reposotories.
  (See the sample config file for details.)
  
If you don't want to perform any of these tasks, simply leave out the relevant
hashref, or alternatively, leave the entries in place but
keep the `folders` array empty (not applicable to the MySQL section).
  
## Other Notes

### Connecting on a non-standard SSH port

This script does not allow the SSH port number for a server to be specified.
That might make it seems as if the script can only back up servers with SSH
running on the standard port 22, but that is not the case.

If you have a serer running on a non-standard port, you need to make an entry
for the server in the SSH config file for the user that will be running
the script (`~/.ssh/config`). If the file does not exist you'll need to create
it. You'll need to add an entry something like:

	Host my_server.com
		Port 2222
		
The above example specifies that the server `my_server.com` has SSH running on
port 2222.