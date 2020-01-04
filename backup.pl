#!/usr/bin/perl

use strict;
use warnings;
use English qw( -no_match_vars );
use Carp;
use Getopt::Std; # for commandline args
use IO::CaptureOutput 'capture_exec'; # for reliable shelling out
use JSON; # imports encode_json, decode_json, to_json and from_json
use String::ShellQuote; # for sanitising strings when shelling out

my $description = <<'ENDDESC';
#==============================================================================#
# Server Backup Script
#==============================================================================#
# 
# A simple backup script for backing up data on one Linux server from another
# via SSH.
#
# This script is run on the server being backed up to, and the script pulls the
# data off the server over SSH.
#
# The script is designed to be run nightly via cron, and retains 7 coppies, one
# for every day of the week.
# 
# Flags:
# ------
# -c - REQUIRED - the path to the JSON file contianing the config information
#      describing the backup to be performed.
# -v - enter verbose mode
# -d - enter debug mode  (implies -v)
#
# Returns Codes:
# --------------
# 0 - success
# 1 - error
#
#==============================================================================#
ENDDESC

#
# Define 'global' variables
#

# version info
use version; our $VERSION = qv('0.3');

# counter for errors while shelling out
my $NUM_ERRORS = 0; 

#
# Process arguments
#
my %flags;
unless(getopts('c:vd', \%flags)){
	print "FATAL ERROR - invalid arguments - see documentation below:\n\n$description\n";
    exit 1;
}
my $json_path = $flags{c};
unless($json_path && -f $json_path){
	print "FATAL ERROR - no valid coniguration file path provided - see documentation below:\n\n$description\n";
    exit 1;
}
my $verbose = 0;
my $debug = 0;
if($flags{d}){
    $verbose = 1;
    $debug = 1;
    print "DEBUG - entering debug mode (verbose implied)\n";
}elsif($flags{v}){
    $verbose = 1;
    print "INFO - entering verbose mode\n";
}

#
# Parse the config file
#
my $config = load_config($json_path);
my $SSH = $config->{localPaths}->{ssh};
unless(defined $SSH && -f $SSH){
	print "FATAL ERROR - invalid SSH path '$SSH'\n";
	exit 1;
}
my $SCP = $config->{localPaths}->{scp};
unless(defined $SCP && -f $SCP){
	print "FATAL ERROR - invalid SCP path '$SCP'\n";
	exit 1;
}
my $MKDIR = $config->{localPaths}->{mkdir};
unless(defined $MKDIR && -f $MKDIR){
	print "FATAL ERROR - invalid mkdir path '$MKDIR'\n";
	exit 1;
}
unless(defined $config->{localPaths}->{backupBaseDir} && -d $config->{localPaths}->{backupBaseDir}){
	print "FATAL ERROR - backup base $config->{localPaths}->{backupBaseDir} does not exist\n";
	exit 1;
}

#
# Calculate which of the rolling backups to target
#
my @days = qw{Sun Mon Tue Wed Thur Fri Sat};
my @datetime = localtime time;
my $daily_backup_dir = $config->{localPaths}->{backupBaseDir}.$days[$datetime[6]].q{/};
print "INFO - daily backup dir calculated: $daily_backup_dir\n" if $verbose;
# make sure the daily directory exists, if not, try create it
unless(-d $daily_backup_dir){
	unless(-d $daily_backup_dir){
		print "Creating daily backup dir ...\n";
		my $cout = exec_command(qq{$MKDIR }.shell_quote($daily_backup_dir));
		unless($cout->{success}){
			print "\nFATAL ERROR - failed to create daily backup dir $daily_backup_dir\n";
			exit 1;
		}
	}
}

#
# Loop through the defined servers
#
SERVER:
foreach my $server (@{$config->{servers}}){
	# make sure we have at least a possibly valid server definition
	## no critic (ProhibitEnumeratedClasses);
	unless(defined $server->{fqdn} && $server->{fqdn} =~ m/^[-a-zA-Z0-9.]+$/sx && defined $server->{sshUsername} && $server->{sshUsername} =~ m/^[a-zA-Z0-9_]+$/sx){
		print "\nERROR - found invalid or incomplete server definition - skipping\n";
		next SERVER;
	}
	## use critic
	
	print "\n*** SERVER=$server->{fqdn} (as $server->{sshUsername}) ***\n";
	
	# get the local backup dir
	my $server_backup_dir = $daily_backup_dir.$server->{fqdn}.q{/};
	print "INFO - server backup dir calculated: $server_backup_dir\n" if $verbose;
	unless(-d $server_backup_dir){
		print "Creating backup dir for server ...\n";
		my $cout = exec_command(qq{$MKDIR }.shell_quote($server_backup_dir));
		unless($cout->{success}){
			print "\nERROR - failed to create server backup dir $server_backup_dir - skipping server\n";
			next SERVER;
		}
	}
	
	#
	# process each backup type
	#
	
	# if configured, try dump the DBs
	# NOTE: for backwards compatability reasons, allow the old dumbAllDBs key as well as the new dumpDBs key
	if(defined $server->{backup_MySQL} && ($server->{backup_MySQL}->{dumpDBs} || $server->{backup_MySQL}->{dumpAllDBs})){
		print "\n* Processing MySQL Databases *\n";
		
		# try to dump the DBs
		eval{
			# make sure we have all the prerequisites
			unless(defined $server->{remotePaths}->{stagingDir}){
				croak(q{remote staging dir not defined});
			}
			unless(defined $server->{backup_MySQL}->{mysqldump}){
				croak(q{remote mysqldump path not specified});
			}
			
			# dump the DBs
			my $remote_db_file = $server->{remotePaths}->{stagingDir}.'databases.sql';
			print "INFO - using remote DB file: $remote_db_file\n" if $verbose;
			print "Dumping DBs ... \n";
			my $remote_cmd = shell_quote($server->{backup_MySQL}->{mysqldump}).q{ -u }.shell_quote($server->{backup_MySQL}->{user});
			if($server->{backup_MySQL}->{password}){
				$remote_cmd .= q{ }.shell_quote("--password=$server->{backup_MySQL}->{password}");
			}
			if($server->{backup_MySQL}->{host}){
				$remote_cmd .= q{ -h }.shell_quote($server->{backup_MySQL}->{host});
			}
			if($server->{backup_MySQL}->{port}){
				$remote_cmd .= q{ -P }.shell_quote($server->{backup_MySQL}->{port});
			}
			if($server->{backup_MySQL}->{databases} && scalar @{$server->{backup_MySQL}->{databases}}){
				print "INFO - dumping ONLY SPECIFIED DBs\n" if $verbose;
				$remote_cmd .= q{ --set-gtid-purged=OFF --databases};
				foreach my $db (@{$server->{backup_MySQL}->{databases}}){
					$remote_cmd .= q{ }.shell_quote($db);
				}
				$remote_cmd .= q{ -P }.shell_quote($server->{backup_MySQL}->{port});
			}else{
				print "INFO - dumping ALL DBs\n" if $verbose;
				$remote_cmd .= q{ --all-databases}.shell_quote($remote_db_file);
			}
			$remote_cmd .= q{ >}.shell_quote($remote_db_file);
			my $cout = exec_command(assemble_ssh_command($server->{sshUsername}, $server->{fqdn}, $remote_cmd));
			if($cout->{success}){
		    	# copy down the dump
		    	print "Downloading the DB dump ...\n";
			    exec_command(assemble_scp_download($server->{sshUsername}, $server->{fqdn}, $remote_db_file, $server_backup_dir));
			}
			
			1; # ensure truthy evaluation on successful execution
		}or do{
			print "ERROR - failed to dump MySQL DBs with error: $EVAL_ERROR\n";
		};
	}else{
		print "\nINFO - skipping MySQL DB backup - not configured\n" if $verbose;
	}
	
	# if configured, try create and download TAR backups
	if(defined $server->{backup_tar} && defined $server->{backup_tar}->{folders} && ref $server->{backup_tar}->{folders} eq 'HASH' && scalar keys %{$server->{backup_tar}->{folders}}){
		print "\n* Processing TAR Folder Backups *\n";
		
		# try to process the backups
		eval{
			# make sure we have all the prerequisites
			unless(defined $server->{remotePaths}->{stagingDir}){
				croak(q{remote staging dir not defined});
			}
			unless(defined $server->{backup_tar}->{tar}){
				croak(q{remote tar path not specified});
			}
			
			# generate the path to save the tar files to, and make sure it exists
			my $tar_base_dir = $server_backup_dir.'tar/';
			unless(-d $tar_base_dir){
				print "Creating folder for storing TAR files ...\n";
				my $cout = exec_command(qq{$MKDIR }.shell_quote($tar_base_dir));
				unless($cout->{success}){
					croak("failed to create folder $tar_base_dir");
				}
			}
			print "INFO - saving archives to $tar_base_dir\n" if $verbose;
			
			# process each specified folder
			foreach my $tar_set (sort keys %{$server->{backup_tar}->{folders}}){
   				my $tar_file = $tar_set.'.tar.gz';
			    my $tar_folder = $server->{backup_tar}->{folders}->{$tar_set};
   
			    # first call TAR on the server
			    print "Generating $tar_file from $tar_folder ...\n";
			    my $remote_cmd = shell_quote($server->{backup_tar}->{tar}).q{ -pczf }.shell_quote($server->{remotePaths}->{stagingDir}.$tar_file).q{ }.shell_quote($tar_folder);
			    my $cout = exec_command(assemble_ssh_command($server->{sshUsername}, $server->{fqdn}, $remote_cmd));
    			if($cout->{success}){
	        		# then scp down the file
		    	    print "Downloading $tar_file ...\n";
		    	    exec_command(assemble_scp_download($server->{sshUsername}, $server->{fqdn}, $server->{remotePaths}->{stagingDir}.$tar_file, $tar_base_dir));
    			}
			}
			
			1; # ensure truthy evaluation on successful execution
		}or do{
			print "ERROR - failed to TAR folders with error: $EVAL_ERROR\n";
		};
	}else{
		print "\nINFO - skipping TAR backup - not configured\n" if $verbose;
	}

	# if configured, try rsync backups
	if(defined $server->{backup_rsync} && defined $server->{backup_rsync}->{folders} && ref $server->{backup_rsync}->{folders} eq 'HASH' && scalar keys %{$server->{backup_rsync}->{folders}}){
		print "\n* Processing rsync Backups *\n";
		
		# try to process the backups
		eval{
			# make sure we have all the prerequisites
			unless(defined $config->{localPaths}->{rsync} && -f $config->{localPaths}->{rsync}){
				croak(q{local path to rsync not defined});
			}
			
			# generate path to save rsynced folders to, and make sure it exists
			my $rsync_base_dir = $server_backup_dir.'rsync/';
			unless(-d $rsync_base_dir){
				print "Creating folder for storing rsynced folders ...\n";
				my $cout = exec_command(qq{$MKDIR }.shell_quote($rsync_base_dir));
				unless($cout->{success}){
					croak("failed to create folder $rsync_base_dir");
				}
			}
			print "INFO - saving rsynced folders in $rsync_base_dir\n" if $verbose;
			
			# loop through all the folders to be rsynced
			RSYNC_FOLDER:
			foreach my $rsync_name (sort keys %{$server->{backup_rsync}->{folders}}){
			    my $rsync_src = $server->{backup_rsync}->{folders}->{$rsync_name};
			    
			    # make sure the destination folder to rsync to exists - if not, try create it
			    my $rsync_dest = $rsync_base_dir.$rsync_name.q{/};
			    unless(-d $rsync_dest){
			    	print "Creating folder to rsync $rsync_src to ...\n";
					my $cout = exec_command(qq{$MKDIR }.shell_quote($rsync_dest));
					unless($cout->{success}){
						print "ERROR - failed to create folder $rsync_dest - skipping rsync of $rsync_src\n";
						next RSYNC_FOLDER;
					}
			    }
			    
			    # execute the rsync
	   			print "Rsyncing $rsync_src to $rsync_dest ...\n";
	   			my $cmd = shell_quote($config->{localPaths}->{rsync}).q{ -avz --delete -e ssh };
	   			$cmd   .= shell_quote($server->{sshUsername}.q{@}.$server->{fqdn}.q{:}.$rsync_src);
	   			$cmd   .= q{ }.shell_quote($rsync_dest);
	   			exec_command($cmd);
			}
			1; # ensure truthy evaluation on successful execution
		}or do{
			print "ERROR - failed to process rsync backups with error: $EVAL_ERROR\n";
        };
	}else{
		print "\nINFO - skipping rsync backup - not configured\n" if $verbose;
	}
	
	# if configured, try create and download SVN dumps
	if(defined $server->{backup_svndump} && defined $server->{backup_svndump}->{folders} && ref $server->{backup_svndump}->{folders} eq 'HASH' && scalar keys %{$server->{backup_svndump}->{folders}}){
		print "\n* Processing SVN Backups *\n";
		
		# try to process the backups
		eval{
			# make sure we have all the prerequisites
			unless(defined $server->{remotePaths}->{stagingDir}){
				croak(q{remote staging dir not defined});
			}
			unless(defined $server->{backup_svndump}->{svnadmin}){
				croak(q{remote svnadmin path not specified});
			}
			unless(defined $server->{backup_svndump}->{ls}){
				croak(q{remote ls path not specified});
			}
			
			# generate path to save svn dumps to, and make sure it exists
			my $svn_base_dir = $server_backup_dir.'svn/';
			unless(-d $svn_base_dir){
				print "Creating folder for storing SVN dump files ...\n";
				my $cout = exec_command(qq{$MKDIR }.shell_quote($svn_base_dir));
				unless($cout->{success}){
					croak("failed to create folder $svn_base_dir");
				}
			}
			print "INFO - saving SVN dumps to $svn_base_dir\n" if $verbose;
			
			# loop through all the folders of SVN Repos
			foreach my $svn_set (sort keys %{$server->{backup_svndump}->{folders}}){
			    my $svn_folder = $server->{backup_svndump}->{folders}->{$svn_set};
	   			print "Backing Up SVN Repos under $svn_folder ...\n";
    
			    # first get a list of all the repos in this set
			    my $remote_cmd = shell_quote($server->{backup_svndump}->{ls}).q{ -1 }.shell_quote($svn_folder);
			    my $cout = exec_command(assemble_ssh_command($server->{sshUsername}, $server->{fqdn}, $remote_cmd), 1);
			    my @repos = split /\n/sx, $cout->{stdout};
   
			    # then loop through all the repos and back them up
			    foreach my $repo (@repos){
			        my $repo_dir = $svn_folder.$repo.q{/};
			        my $dump_file = $server->{remotePaths}->{stagingDir}.$svn_set.q{_}.$repo.q{.svndump};
       
        			# first dump the repo
			        print "\tDumping repo $repo_dir to $dump_file...\n";
			        $remote_cmd = shell_quote($server->{backup_svndump}->{svnadmin}).q{ dump }.shell_quote($repo_dir).q{ --quiet > }.shell_quote($dump_file);
			        $cout = exec_command(assemble_ssh_command($server->{sshUsername}, $server->{fqdn}, $remote_cmd));
        			if($cout->{success}){
			            # if that went OK, download it
	           			print "\tDownloading $dump_file ...\n";
	           			exec_command(assemble_scp_download($server->{sshUsername}, $server->{fqdn}, $dump_file, $svn_base_dir));
        			}
			    }
			}
			
			1; # ensure truthy evaluation on successful execution
		}or do{
			print "ERROR - failed to process SVN backups with error: $EVAL_ERROR\n";
        };
	}else{
		print "\nINFO - skipping SVN backup - not configured\n" if $verbose;
	}
}

#
# Print final summary
#
if($NUM_ERRORS){
    print "\n\nWARNING - THERE WERE $NUM_ERRORS ERRORS (scroll up for details)\n\n";
}else{
    print "\n\nDONE (no errors)\n\n";
}

#
# === Helper Functions ===
#

#####-SUB-######################################################################
# Type       : SUBROUTINE
# Purpose    : A function to load, parse and validate a JSON config file
# Returns    : A hashref representing the config object extracted from the JSON
# Arguments  : 1) the path to the JSON file to parse
# Throws     : Exits on error.
# Notes      :
# See Also   :
sub load_config{
	my $config_path = shift;
	
	# slurp the contents of the config file
	open my $CONFIG_FH, '<', $config_path or croak("FATAL ERROR - failed to open $config_path with error: $OS_ERROR");
	my $config_json = do{local $/ = undef; <$CONFIG_FH>};
	close $CONFIG_FH;
	
	# parse to JSON
	my $config_hashref = decode_json($config_json); # croaks on error
	
	# validate the config
	unless(defined $config_hashref->{localPaths} && defined $config_hashref->{servers}){
		print "FATAL ERROR - config data loaded from $config_path is not valid\n";
		exit 1;
	}
	
	# return the config
	return $config_hashref;
}

#####-SUB-######################################################################
# Type       : SUBROUTINE
# Purpose    : Function to execute a terminal command
# Returns    : a hashref indexed by stdout, stderr, exit_code, and success
# Arguments  :  1) the command to execute as a string
#               2) OPTIONAL - a true value to indicated that debug mode should
#                  be over-ridden
# Throws     : 
# Notes      : When in debug mode, the command will be printed rather than
#              executed unless a true value is passed as a second argument.
# See Also   :
sub exec_command{
    my $cmd = shift;
    my $override_debug = shift;
    my $dodebug = $debug;
    if($override_debug){
        $dodebug = 0;
    }
    
    # if we're debugging, print and return dummy data
    if($dodebug){
        print "DEBUG - would execute command: $cmd\n";
        return {
            success => 1,
            exit_code => 0,
        };
    }
    
    # otherwise go ahead and shell out
    print "INFO - executing: $cmd\n" if $verbose;
    my ($stdout, $stderr, $success, $exit_code) = capture_exec($cmd);
    
    # record an error if there was one
    unless($success){
    	$NUM_ERRORS++;
    }
    
    # print details if in verbose mode, or print details if not success
    if($verbose){
        print "\tstdout: $stdout\n" if $stdout;
        print "\tstderr: $stderr\n" if $stderr;
        print "\texit code: $exit_code\n";
        print "\tsuccess: $success\n\n";
    }elsif(!$success){
        print "WARNING - non-success exit code:\n\tcommand: $cmd\n\tstdout: $stdout\n\tstderr: $stderr\n\texit code: $exit_code\n";
    }
    
    # assemble the hashref and return
    return {
        stdout => $stdout,
        stderr => $stderr,
        success => $success,
        exit_code => $exit_code,
    };
}

#####-SUB-######################################################################
# Type       : SUBROUTINE
# Purpose    : Assemble and properly escape a command to be executed over SSH
# Returns    : A string ready to be executed.
# Arguments  : 1) the SSH username to connect with
#              2) the SSH server to connect to
#              3) a command properly escaped for local execution
# Throws     : croaks on invalid args
# Notes      :
# See Also   :
sub assemble_ssh_command{
	my $uname = shift;
	my $server = shift;
	my $command = shift;
	
	# check args
	unless($server && $uname && $command){
		croak('assemble_ssh_command(): invalid args');
	}
	
	# assemble and return the SSH command
	return $SSH.q{ }.shell_quote($uname.q{@}.$server).q{ }.shell_quote($command);
}

#####-SUB-######################################################################
# Type       : SUBROUTINE
# Purpose    : Assemble a properly escape SCP command for downloading a file
# Returns    : A string ready to be executed
# Arguments  : 1) the ssh username to connect to the remote sever with
#              2) the ssh server to connect to
#              3) the path on the server of the file to be downloaded
#              4) the local folder path to download the remote file to
# Throws     : croaks on invalid args
# Notes      :
# See Also   :
sub assemble_scp_download{
	my $uname = shift;
	my $server = shift;
	my $remote_path = shift;
	my $local_path = shift;
	
	# check args
	unless($server && $uname && $remote_path && $local_path){
		croak('assemble_scp_download(): invalid args');
	}
	
	# assemble and return the SCP command
	return $SCP.q{ -p }.shell_quote($uname.q{@}.$server.q{:}.$remote_path).q{ }.shell_quote($local_path);
}