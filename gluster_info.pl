#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : gluster_info.pl
#: Version : 1.3.0
#: Path    : /usr/local/sbin/gluster_info.pl
#: Params  : --status_url <server-status URL> --worker_count <busy limit>
#: Options : -h | --daemon | --stop
#: Desc    : Dynamically collects Gluster and kernel stats pending busy workers
#: Changes : 
#: 1.0.1   : Added spawn_revert, Reverting storagetier to legacy
#: 1.1.0   : Updated the --stop process, wrote --help
#: 1.2.0   : Capturing top, vmstat, ps, iostat, mpstat, free
#:         : Outputting raw netstat
#:         : Recording /proc/{vmstat,meminfo} stats
#:         : Capturing gluster {read,write}-perf
#:         : Capturing OMSA controller and battery stats
#: 1.2.1   : Logging error messages to separate file
#: 1.2.2   : Commented all the things, cleaned up some spawn output
#: 1.2.3   : Prepending vmstat output with timestamp
#: 1.3.0   : Added sar output, changed how statedumps are performed
#:         : Using core mods for hostname, timestamps, temp dirs
#:         : Added banner sub for multiline log messages
#:         : Fixed some perlcritic issues
#:         : Using LWP::UserAgent instead of curl/lynx
#:         : Added lsof network output, ps thread output
#: To do's :
#:         : Use SIGTERM instead of stop file
#:         : Update logger to take name, and stdout or stderr
#:         : Actually use SIGCHLD
#:         : Unify %pids and %spawns
#: License :
# Copyright (c) 2015 SmartVault, Inc.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

use strict;
use warnings;

use Getopt::Long;
use Sys::Hostname;
use LWP::UserAgent;
use POSIX qw(strftime);
use File::Temp;
use POSIX qw /:sys_wait_h/;

# Global vars
my $version     = '1.3.0';
my $hostname    = hostname;
my $daemon_file = '/tmp/gluster_info_daemon';
my $stop_file   = '/tmp/stop_gluster_info';
my $output_dir  = '/home/release/gluster_info';
my $log_file    = "$output_dir/gluster_info.log";
my $err_file    = "$output_dir/gluster_info.err";

# Help if no args supplied
if (!@ARGV) { help(0) }

# Handle args
my %args;
GetOptions(
    'h|help'         => \$args{help},
    'v|version'      => \$args{version},
    'status_url=s'   => \$args{status_url},
    'worker_limit=s' => \$args{worker_limit},
    'stop'           => \$args{stop},
    'daemon'         => \$args{daemon},
    'skip_revert'    => \$args{skip},
    'once'           => \$args{once}
) or help(1);

# Help me
if ($args{help}) { help(0) }

# Show version
if ($args{version}) {
    printf "Version: %s\n", $version;
    exit;
}

# Stop the daemon
if ($args{stop}) {
    # Bug out if the daemon isn't running
    if (! -f $daemon_file) {
        print "[-] gluster_info.pl is not running\n";
        exit;
    }

    # Touch the stop file
    `touch $stop_file`;
    if ($? > 0) { die "[!] Failed to create $stop_file\n" }

    $| = 1;

    # Wait for the daemon to be killed
    print "[*] Stopping gluster_info.pl ";
    my $kill_it = 0;

    # Pull in the daemon's pid
    if (-f $daemon_file) {
        open my $daemon_handle, '<', $daemon_file
          or die "[!] Failed to read daemon pid: $!\n";
        my $daemon_pid = <$daemon_handle>;
        close $daemon_handle;

        # Print an update for every second
        while (-f $stop_file) {
            print ".";
            # If the stop takes longer than 30 kill -9 it
            if ($kill_it >= 30) {
                `kill -9 $daemon_pid >/dev/null 2>/dev/null` if -f "/proc/$daemon_pid";
            }
            sleep 1;
            $kill_it ++;
        }
    }

    print "\n[+] Done\n";

    exit;
}

# Sanity checks
if ((!$args{status_url}) or (!$args{worker_limit})) {
    die "[!] Cannot start, both --status_url and --worker_limit are required\n";
}
else {
    my $check_url = get_worker_count($args{status_url});
    if ($check_url == -1) {
        die "[!] Failed to retireve server-status, please check URL\n";
    }
    elsif ($args{worker_limit} > 255) {
        die "[!] Worker limit greater than 255, cannot start\n";
    }
}

# Don't start if daemon is already running
if (-f $daemon_file) {
    die "[!] gluster_info.pl appears to be running daemonized\nUse --stop to resolve this\n";
}

# Don't start if we have already reverted storage tiers,
# remove this if we no longer need to perform this step
unless ($args{skip}) {
    if (-f '/tmp/redacted') {
        die "[!] '/tmp/redacted' exists, will not be reverting storage tiers\nUse --skip_revert to continue\n";
    }
}

# Start daemonized
if ($args{daemon}) {
    # Remove any pre-existing stop files
    if (-f $stop_file) {
        print "[?] Stop file exists, removing it\n";
        unlink $stop_file or die "[!] Failed to remove stop file: $!\n";
    }

    # Fork and daemonize
    print "[*] Starting gluster_info.pl\n";
    chdir '/'                      or die "[!] Failed to chdir '/': $!\n";
    open my $oldout, '>&', STDOUT  or die "[!] Failed to write to STDOUT: $!\n";
    open STDIN,   '<', '/dev/null' or die "[!] Failed to read '/dev/null': $!\n";
    open STDOUT,  '>', '/dev/null' or die "[!] Failed to write to '/dev/null': $!\n";
    my $daemon_pid = fork // die "[!] Failed to daemonize: $!\n";

    unless ($daemon_pid) {
        main($args{status_url}, $args{worker_limit}, $daemon_file);
    }

    # Record the daemon's pid
    open my $daemon_handle, '>', $daemon_file 
      or die "[!] Failed to write to daemon pid to $daemon_file: $!\n";
    printf $daemon_handle "%i", $daemon_pid;
    close $daemon_handle;

    print $oldout "[+] Done\n";
    close $oldout;

    exit;
}
# Start interactive
else {
    main($args{status_url}, $args{worker_limit}, 0);
}

# Usage
sub help {
    my ($exit_code) = @_;

    print <<'EOH';
gluster_info.pl -- Dynamically collects system Gluster stats

Options:
  -h|--help            Displays this message

Required Parameters:
  --status_url         Location of Apache server-status?auto page
  --worker_limit       Number of active workers to look for

Optional Paramters:
  --daemon             Daemonizes the process
  --stop               Stops the daemon mode
  --skip_revert        Skips reverting of redacted
  --once               Daemon kills self after processing trigger

John Shields -- SmartVault Corporation - 2015
    
EOH

    exit $exit_code;
}

# Initialize which jobs will be executed
# Create a $pids and $spawns key,value pair
sub init {

    my %pids   = ();
    my %spawns = (); 

    # Disabled 1.3.0
    #$pids{profile}   = 0;
    #$spawns{profile} = \&spawn_profile;

    $pids{statedump}   = 0;
    $spawns{statedump} = \&spawn_statedump;

    $pids{dirty}   = 0;
    $spawns{dirty} = \&spawn_dirty;

    $pids{netstat}   = 0;
    $spawns{netstat} = \&spawn_netstat;

    $pids{httpd_status}   = 0;
    $spawns{httpd_status} = \&spawn_httpd_status;

    # Disable 1.3.0
    #$pids{sos}   = 0;
    #$spawns{sos} = \&spawn_sos;

    $pids{revert}   = 0;
    $spawns{revert} = \&spawn_revert;

    $pids{top}   = 0;
    $spawns{top} = \&spawn_top;

    $pids{vmstat}   = 0;
    $spawns{vmstat} = \&spawn_vmstat;

    $pids{ps_faux}   = 0;
    $spawns{ps_faux} = \&spawn_ps_faux;

    $pids{proc_meminfo}   = 0;
    $spawns{proc_meminfo} = \&spawn_proc_meminfo;

    $pids{proc_vmstat}   = 0;
    $spawns{proc_vmstat} = \&spawn_proc_vmstat;

    # Disabled 1.3.0
    #$pids{gfs_perf}   = 0;
    #$spawns{gfs_perf} = \&spawn_gfs_perf;

    $pids{iostat}   = 0;
    $spawns{iostat} = \&spawn_iostat;

    # Disabled 1.3.0
    #$pids{mpstat}   = 0;
    #$spawns{mpstat} = \&spawn_mpstat;

    $pids{free}   = 0;
    $spawns{free} = \&spawn_free;

    $pids{omsa}   = 0;
    $spawns{omsa} = \&spawn_omsa;

    $pids{sar}   = 0;
    $spawns{sar} = \&spawn_sar;

    $pids{lsof_network}   = 0;
    $spawns{lsof_network} = \&spawn_lsof_network;

    $pids{ps_eLF}   = 0;
    $spawns{ps_eLF} = \&spawn_ps_eLF;

    return \%pids, \%spawns;
}

# Logger routine
sub logger {
    my ($message) = @_;

    my $timestamp = gen_timestamp();

    # Strip any new line or return characters
    $timestamp =~ s/(\n|\r)//g;
    $message   =~ s/(\n|\r)//g;

    open my $lf, '>>', $log_file  or die "[!] Failed to open '$log_file': $!\n";
    printf $lf "[%s] %s\n", "$timestamp", "$message";
    close $lf ;

    return 0;
}

# Generate a time stamp
sub gen_timestamp {

    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", localtime;

    return $timestamp;
}

# Print banner for multiline logs
sub banner {
    my ($timestamp) = @_;
    
    my $equals = '=' x length($timestamp);

    my $lines  = sprintf "\n%s\n", $equals;
       $lines .= $timestamp;
       $lines .= sprintf "\n%s\n\n", $equals;

    return $lines;
}

# Retrurn Gluster volume info
sub get_volume_info {
    my ($volume) = @_;

    my @info = `gluster volume info $volume 2>/dev/null`;
    if ($? > 0) { die "[Profile] [!] Failed to retrieve gluster info\n" }

    return \@info;
}

# Create a Gluster statedump        
sub gen_fuse_statedump {
    my ($volume) = @_; 

    # Get FUSE volume pid
    my @ps_ef = `ps -ef`;
    my @glusters = grep {/glusterfs/} @ps_ef;
    my @pids = grep {!/glusterfshd/} @glusters;
    @pids = grep {!/nfs/} @pids;
    my ($pid_line) = grep {/$volume/} @pids;
    my @split_pid = split /\s+/, $pid_line;
    my $pid = $split_pid[1];

    my $statedump = `kill -USR1 $pid`;
    if ($? > 0) {
        die "[Statedump] [!] Failed to create gluster $volume statedump\n";
    }

    return 1;
}

# Main routine
sub main {
    my ($status_url, $worker_limit, $daemon_pid) = @_;

    # Get pids and jobs we'll be executing
    my ($pids, $spawns) = init;

    # Write all output to daemon log if daemonized
    open STDOUT, '>>', $log_file if $daemon_pid;
    open STDERR, '>>', $err_file if $daemon_pid;
    
    # Create a killed directory, contains who's been killed
    my $killed_dir = File::Temp->newdir(CLEANUP => 0);

    # Cheap solution to zombie procs
    $SIG{CHLD} = 'IGNORE';

    # Create the output directory if it doesn't exist
    unless (-d $output_dir) {
        mkdir $output_dir or die "[Main] [!] Failed to create $output_dir\n";
    }

    # Handle SIGINT if running interactively
    $SIG{'INT'} = sub {
        logger('[Main] Interrupted');
        cleanup($pids, 0);
        logger('[Main] Killed all children');
        unlink glob "$killed_dir/*";
        rmdir $killed_dir;
        logger('[Main] Removed killed dir');
        print "[!] Interrupted!\n";
        logger('[Main] Exiting');
        exit;
    };

    # Log that we have started
    if ($daemon_pid) {
        logger('[Main] Starting daemonized');
    }
    else {
        logger('[Main] Starting');
    }

    # Log that we have been started with --once
    if ($args{once}) {
        logger('[Main] --once detected, killing self after first cleanup');
    }

    # Begin primarly program loop
    my $has_been_killed = 0;
    while() {

        # Kill everything if stop file is present
        if (-f $stop_file) {
            &logger('[Main] Stop file exists, killing everything');
            &cleanup($pids, 1);
            &logger('[Main] Killed all children');
            if ($daemon_pid) {
                unlink $daemon_pid or die "[Main] [!] Failed to remove '$daemon_pid': $!\n";
            }
            unlink $stop_file or die "[Main] [!] Failed to remove stop file: $!\n";
            &logger('[Main] Exiting daemon');
            unlink glob "$killed_dir/*";
            rmdir $killed_dir;
            exit;
        }

        # Get current worker count
        my $worker_count = get_worker_count($status_url);
        logger("[Main] Worker count: $worker_count");

        # If the worker count exceeds our limit or failed to return a value
        # then spawn all of our defined jobs
        if ( ($worker_count > $worker_limit) or ($worker_count == -1) ) {

            # Loop over all our jobs
            for my $pid (keys %$pids) {

                # If job is not running, start it
                if (!$pids->{$pid}) {
                    $pids->{$pid} = fork // die "[Main] [!] Can't fork: $!\n";

                    # We've forked, start the job
                    unless ($pids->{$pid}) {
                        # Once job is started, reset SIGINT handling
                        $SIG{'INT'} = 'DEFAULT';

                        # The spawn_httpd_status requires the status URL
                        if ($pid =~ /httpd_status/) {
                            $spawns->{$pid}->($killed_dir, $status_url);
                        }
                        else {
                            $spawns->{$pid}->($killed_dir);
                        }

                        exit;
                    }
                }
            }
        }

        # If we are below our worker limit, clean up everything
        else {
            $pids = cleanup($pids, 0);
        }

        sleep 1;

    }

    # Remove our daemon file when we exit the while loop
    if ($daemon_pid) {
        unlink $daemon_pid or die "[Main] [!] Failed to remove '$daemon_pid': $!\n";
    }

    return 0;
} 

# Return number of busy workers
sub get_worker_count {
    my ($status_url) = @_;

    my $ua = LWP::UserAgent->new();
    $ua->agent('get_worker_count');
    $ua->timeout(3);

    # Repsonse object from LWP GET
    my $response = $ua->get($status_url);
    
    # Return the number of busy workers
    if ($response->is_success) {
        my $content = $response->decoded_content;
        $content =~ m/(BusyWorkers: (\d+))/;
        my $worker_count = $2;
        
        return $worker_count;
    }
    # if we timeout getting workers, return -1
    else {
        return -1;
    }
}

# Clean up all running jobs
sub cleanup {
    my ($pids, $killed) = @_;
    
    # Boolean to determine if we did anything
    my $actually_cleaned = 0;

    # Gather all running jobs
    my @running = ();
    for my $pid (keys %$pids) {
        push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
    }

    # If we have any running jobs, log we are killing them
    if (@running) {
        logger('[Clean up] Killing child procs...');
    }

    # Loop over all jobs until all are dead
    while(@running) {

        # kill -9 all jobs if stop file present
        if (-f $stop_file) {
            logger('[Clean up] Stop file present, forcefully killing');
            $killed = 1;
        }

        # Recheck our running jobs
        @running = ();
        for my $pid (keys %$pids) {
            push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
        }

        # Kill all jobs that are running
        for my $pid (@running) {
            # Forcefully kill job
            if ($killed) {
                `kill -9 $pid >/dev/null 2>/dev/null` if -d "/proc/$pid";
                pop @running;
            }

            # Gracefully kill job
            `kill $pid >/dev/null 2>/dev/null` if -d "/proc/$pid";
            pop @running;
        }

        # Recheck our running jobs
        @running = ();
        for my $pid ( keys %$pids) {
            push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
        }

        # Sleep quarter second for kills to process
        sleep .25;

        # Indicate we actually did the kills
        $actually_cleaned = 1;
    }

    # Reset pid values to zero
    for my $pid (keys %$pids) {
        $pids->{$pid} = 0;
    }

    # Log that we killed the running jobs
    if ($actually_cleaned) {
        logger('[Clean up] Killed all child procs');
        # If running with --once create the stop file
        if ($args{once}) {
            logger('[Clean up] Killing main');
            `touch $stop_file`;
            if ($? > 0) { die "[Clean up] [!] Failed to create '$stop_file'\n" }
        }
    }

    return $pids;
}

# Enable Gluster profiling and collect profile info
sub spawn_profile {
    my ($killed_dir) = @_;

    my $dying          = "$killed_dir/profile";
    my $gluster_volume = 'redacted'; ##CHANGE
    my $profile_dir    = "$output_dir/profile";
    my $profile_file   = sprintf "%s/%s", $profile_dir, time;

    # Create output directory
    unless (-d $profile_dir) {
        mkdir $profile_dir or die "[Profile] [!] Failed to create $profile_dir: $!\n";
    }

    # Open my log
    open(my $profile_handle, '>>', $profile_file)
      or die "[Profile] [!] Failed to open '$profile_file': $!\n";

    # Gracefully exit routine
    my $killed_me = sub {
        my ($filehandle, $volume, $profile_file) = @_;

        # Indicate that we've been killed
        system("touch $dying") == 0 and die "[Profile] [!] Failed to create touch file: $!\n";
        logger("[Profile] Received SIGTERM");

        # Check to see if profiling is enabled
        my $volume_info = get_volume_info($volume);
        if (grep {/^diagnostics/} @$volume_info) {
            # Stop profiling if enabled
            my $stopped = `gluster volume profile $gluster_volume stop >/dev/null 2>/dev/null`;
            if ($? > 0) { die "[Profile] [!] Failed to disable profiling\n" }
            logger("[Profile] Profiling stopped on '$gluster_volume'");
        }

        # Close log file
        close($filehandle);
        logger("[Profile] Profile output file '$profile_file' closed");

        # Removing dying file
        unlink $dying or die "[Profile] [!] Failed to unlink '$dying': $!\n";
        logger('[Profile] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying    
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($profile_handle, $gluster_volume, $profile_file);
        };
    }

    # Log that we've been spawned
    logger('[Profile] Profile process created');

    # Check to see if profiling is enabled
    my $volume_info = get_volume_info($gluster_volume);
    unless (grep {/^diagnostics/} @$volume_info) {
        # Start profiling if disabled
        my $started = `gluster volume profile $gluster_volume start >/dev/null 2>/dev/null`;
        if ($? > 0) { die "[Profile] [!] Failed to start profiling\n" }
        logger("[Profile] Profiling started on '$gluster_volume'");
    }

    # Log where we are logging to
    logger("[Profile] output file is '$profile_file'");

    # Collect profile output every three seconds
    while () {
        my $timestamp = gen_timestamp;
        my @profile_stats = `gluster volume profile $gluster_volume info 2>/dev/null`;
        if ($? > 0) { die "[Profile] Failed to retrieve profile stats\n" }

        # If we actually got something log it
        # No output can be returned if Gluster is busy
        if (@profile_stats) {
            my $banner = banner($timestamp);
            print $profile_handle $banner;
            print $profile_handle @profile_stats;
        }

        sleep 3;
    }

    exit;
}

# Generate a Gluster statedump
sub spawn_statedump {
    my ($killed_dir) = @_;

    my $dying          = "$killed_dir/statedump";
    my $gluster_volume = 'redacted'; ##CHANGE
    my $statedump_dir  = "$output_dir/statedump";
    my $statedump_time = sprintf "%s/%s", $statedump_dir, time;
    my $prev_dump_dir  = '/var/run/gluster';

    # Create statedump holding directory
    unless (-d $statedump_dir) {
        mkdir $statedump_dir or die "[Statedump] [!] Failed to create $statedump_dir: $!\n";
    }

    # Create statedump directory for this execution
    unless (-d $statedump_time) {
        mkdir $statedump_time or die "[Statedump] [!] Failed to create $statedump_time: $!\n";
    }

    # Gracefully exit routine
    my $killed_me = sub {
        my ($volume) = @_;

        # Indicate we've been killed
        system("touch $dying") == 0 and die "[Statedump] [!] Failed to create touch file: $!\n";
        logger('[Statedump] Received SIGTERM');

        # Reset statedump directory to previous value
        my $reset_dump_dir = `gluster volume set $gluster_volume server.statedump-path $prev_dump_dir >/dev/null 2>/dev/null`;
        if ($? > 0) { die "[Statedump] [!] Failed to reset statedump directory\n" }
        logger("[Statedump] Reset statedump directory to '$prev_dump_dir'");

        # Remove dying file
        unlink $dying or die "[Statedump] [!] Failed to unlink '$dying': $!\n";
        logger('[Statedump] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->();
        }
    }

    # Log that we've been spawned
    logger('[Statedump] Statedump process created');
    
    # Change statedump directory
    my $set_dump_dir = `gluster volume set $gluster_volume server.statedump-path $statedump_time >/dev/null 2>/dev/null`;
    if ($? > 0) { die "[Statedump] [!] Failed to set statedump directory\n" }
    logger("[Statedump] Statedump for '$gluster_volume' set to '$statedump_time'");

    # Create statedump every second
    while () {
        gen_fuse_statedump($gluster_volume);
        sleep 1;
    }

    exit;
}

# Collect dirty pages and writeback values
sub spawn_dirty {
    my ($killed_dir) = @_;

    my $dying     = "$killed_dir/dirty";
    my $dirty_dir = "$output_dir/dirty";
    my $dirty_log = sprintf "%s/%s", $dirty_dir, time;

    # Create my output directory
    unless (-d $dirty_dir) {
        mkdir $dirty_dir or die "[Dirty] [!] Failed to create $dirty_dir: $!\n";
    }

    # Open my log file
    open my $dirty_handle, '>>', $dirty_log
      or die "[Dirty] [!] Failed to open '$dirty_log': $!\n";

    # Gracefully handle SIGTERM
    my $killed_me = sub {
        my ($filehandle, $dirty_file) = @_;

        # Indicate I've been killed
        system("touch $dying") == 0 and die "[Dirty] [!] Failed to create dying file: $!\n";
        logger('[Dirty] Received SIGTERM');

        # Close log handle
        close $filehandle;
        logger("[Dirty] Closed log file '$dirty_log'");

        # Remove dying file
        unlink $dying or die "[Dirty] [!] Failed to unlink '$dying': $!\n";
        logger('[Dirty] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($dirty_handle, $dirty_log);
        }
    }

    # Log that I've been spawned
    logger('[Dirty] Collecting dirty page stats');
    logger("[Dirty] Logging dirty page stats to '$dirty_log'");
    
    # Parse /proc/vmstat every second
    while () {
        open my $vmstat_fh, '<', '/proc/vmstat'
          or die "[Dirty] [!] Failed to open '/proc/vmstat': $!\n";
        chomp(my @vmstat = <$vmstat_fh>);
        close $vmstat_fh;

        # Extract dirty pages and writeback
        my @dirty = grep {/nr_(d|w)/} @vmstat;

        # Build log line containing extracted values
        my $log_line = sprintf('[%s]', gen_timestamp);
        for my $stat (@dirty) {
            my @split = split / /, $stat;
                $log_line .= sprintf(' %s -> % 9i ;', $split[0], $split[1]);
        }

        # Clean up log line
        $log_line =~ s/(\n|\r)//g;
        $log_line =~ s/\s*;$//;

        # Write log line
        print $dirty_handle "$log_line\n";
        sleep 1;
    }

    exit;
}

# Collect netstat data
sub spawn_netstat {
    my ($killed_dir) = @_;

    my $dying       = "$killed_dir/netstat";
    my $netstat_dir = "$output_dir/netstat";
    my $netstat_log = sprintf "%s/%s", $netstat_dir, time;
    my $netstat_raw = sprintf "%s.raw", $netstat_log;

    # Create my output directory
    unless (-d $netstat_dir) {
        mkdir $netstat_dir or die "[netstat] [!] Failed to create '$netstat_dir': $!\n";
    }

    # Open my parsed netstat log
    open my $netstat_handle, '>>', $netstat_log
      or die "[netstat] [!] Failed to open '$netstat_log': $!\n";

    # Open my raw netstat log
    open my $netstat_handle_raw, '>>', $netstat_raw
      or die "[netstat] [!] Failed to open '$netstat_raw': $!\n";

    # Gracefully die    
    my $killed_me = sub {
        my ($log_handle, $netstat_log, $raw_handle, $netstat_raw) = @_;

        # Indicate I've been killed
        system("touch $dying") == 0 and die "[netstat] [!] Failed to create dying file: $!\n";
        logger('[netstat] Received SIGTERM');

        # Close parsed log handle
        close $log_handle;
        logger("[netstat] Closed log file '$netstat_log'");

        # Close raw log handle
        close $raw_handle;
        logger("[netstat] Closed log file '$netstat_raw'");

        # Remove dying file
        unlink $dying or die "[netstat] [!] Failed to unlink '$dying': $!\n";
        logger('[netstat] Gracefully exited');
        
        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($netstat_handle, $netstat_log, $netstat_handle_raw, $netstat_raw);
        }
    }

    # Log that I've been spawned
    logger('[netstat] Collecting netstat activity');
    logger("[netstat] Logging netstat activity to '$netstat_log'");
    logger("[netstat] Logger raw netstat output to '$netstat_raw'");

    # Linux TCP states
    my @states = (
        'CLOSE',
        'CLOSE_WAIT',
        'CLOSING',
        'ESTABLISHED',
        'FIN_WAIT1',
        'FIN_WAIT2',
        'LAST_ACK',
        'LISTEN',
        'SYN_RECV',
        'SYN_SENT',
        'TIME_WAIT'
    );

    # Collect netstat info every second
    while () {
        # Set my states to zero
        my %count = ();
        for (@states) {
            $count{$_} = 0;
        }

        # Execute netstat -nap
        my @raw_netstat = `netstat -nap`;
        if ($? > 0) { die "[netstat] [!] Faile to execute netstat\n" }
        my $timestamp = gen_timestamp;
        
        # Write out the raw data
        my $banner = banner($timestamp);
        print $netstat_handle_raw $banner;
        print $netstat_handle_raw @raw_netstat;        

        # Extract only TCP stats
        my @tcp = grep {/^tcp/} @raw_netstat;
        
        # Count the occurrences of each state
        for my $conn (@tcp) {
            my @delim = split /\s+/, $conn;
            $count{$delim[5]} ++;
        }

        # Initialize log line
        my $log_line = sprintf('[%s]', gen_timestamp);

        # Build my log line
        for my $stype (sort keys %count) {
            if ($count{$stype} > 0) {
                $log_line .= sprintf(' %s -> %i ;', $stype, $count{$stype});
            }
        }

        # Clean up log line
        $log_line =~ s/(\n|\r)//g;
        $log_line =~ s/\s*;$//;

        # Write log line
        print $netstat_handle "$log_line\n";

        sleep 1;
    }

    exit;
}

# Collect what Apache is doing
sub spawn_httpd_status {
    my ($killed_dir, $status_url) = @_;

    my $dying      = "$killed_dir/httpd_status";
    my $status_dir = "$output_dir/httpd_status";
    my $status_log = sprintf "%s/%s", $status_dir, time;
    my $output = "$status_dir/current.html";
    # Build URL for extended status
    $status_url =~ s/\?auto//;

    # Create output directory
    unless (-d $status_dir) {
        mkdir $status_dir or die "[Status] [!] Failed to create '$status_dir': $!\n";
    }

    # Open my log file
    open my $status_handle, '>>', $status_log
      or die "[Status] [!] Failed to open '$status_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($filehandle, $log_file, $temp) = @_;

        # Indicate I've been killed
        system("touch $dying") == 0 and die "[Status] [!] Failed to create dying file: $!\n";
        logger('[Status] Received SIGTERM');

        # Close log handle
        close $filehandle;
        logger("[Status] Closed log file '$status_log'");

        # Remove temp file
        unlink $temp  or die "[Status] [!] Failed to unlink '$temp': $!\n";

        # Remove dying file
        unlink $dying or die "[Status] [!] Failed to unlink '$dying': $!\n";
        logger('[Status] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($status_handle, $status_log, $output);
        }
    }

    # Log that I've been spawned
    logger('[Status] Collecting Apache server-status');

    # Every five seoncds record what Apache is doign
    my $ua = LWP::UserAgent->new();
    $ua->agent('httpd-status');
    $ua->timeout(3);
    my @status = ();
    while () {
        my $timestamp = gen_timestamp;

        my $response = $ua->get($status_url);
        if ($response->is_success) {
            my $raw_html = $response->decoded_content;
            @status = `lynx -dump -width=300 <<EOF\n$raw_html\nEOF\n`;
        }
        else {
            @status = ("Failed to get status\n");
        }

        # Log the Apache status
        my $banner = banner($timestamp);
        print $status_handle $banner;
        print $status_handle @status;

        sleep 5;
    }

    exit;
}

# Generate an SOS file
sub spawn_sos {
    my ($killed_dir) = @_;

    my $dying     = "$killed_dir/sos";
    my $sos_dir   = "$output_dir/sos";
    my $new_sos   = sprintf '%s/%i', $sos_dir, time;
    my $started   = sprintf '%s/%i.started', $sos_dir, time;
    my $completed = sprintf '%s/%i.completed', $sos_dir, time;

    # Create output directory
    unless (-d $sos_dir) {
        mkdir $sos_dir or die "[SOS] [!] Failed to create '$sos_dir': $!\n";
    }

    # Create output directory for this run
    unless (-d $new_sos) {
        mkdir $new_sos or die "[SOS] [!] Failed to create '$new_sos': $!\n";
    }

    # Gracefully die
    my $killed_me = sub {
        my ($completed) = @_;

        # Don't do anything if SOS is still being generated
        if (-f $started) {
            return 0;
        }

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[SOS] [!] Failed to create dying file: $!\n";
        logger('[SOS] Received SIGTERM');

        # Remove completion flag file
        if (-f $completed) {
            unlink $completed or die "[SOS] [!] Failed to unlink '$completed': $!\n";
            logger('[SOS] Removed completed flag');
        }

        # Remove dying file
        unlink $dying or die "[SOS] [!] Failed to unlink '$dying': $!\n";
        logger('[SOS] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying or create an SOS
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    elsif (-f $started) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($completed);
        }
    }

    # Log that I've been spawned
    logger('[SOS] SOS Process created');

    # Create marker file that I'm create an SOS
    system("touch $started") == 0 and die "[SOS] [!] Failed to create started file: $!\n";
    logger("[SOS] Creating SOS report: '$new_sos'");

    # Create an SOS file then do nothing
    while () {
        # Create an SOS file if I haven't yet
        if (! -f $completed) {
            my $sos_report = `sosreport --batch --tmp-dir $new_sos >/dev/null 2>/dev/null`;
            if ($? > 0) { die "[SOS] [!] Failed to create SOS file\n" }
            # Mark that I've completed the sosreport
            system("touch $completed") == 0 and die "[SOS] [!] Failed to create completed file: $!\n";
            logger("[SOS] Completed SOS Report: '$new_sos'");
            unlink $started or die "[SOS] [!] Failed to unlink started file: $!\n";
        }
        # Sleep until killed if I've create an SOS
        else {
            sleep 1; 
        }
    }

    exit;
}

# Revert storage tiers
sub spawn_revert {

    # Don't handle kills
    $SIG{'TERM'} = 'IGNORE';

    # Path to indication file
    my $already_ran = '/tmp/redacted';

    # If I've already ran exit
    if (-f $already_ran) {
        exit;
    }

    # The MySQL command I'm going to run to revert storage tiers
    my $command = "mysql --defaults-extra-file=redacted -e 'redacted;'";

    # Run the MySQL command over SSH on our MySQL server
    my $ssh     = `ssh -i /home/jshields/.ssh/id_rsa jshields\@redacted "$command" >/dev/null 2>/dev/null`;
    if ($? > 0) { die "[Revert] Failed to revert storage tier\n" }

    # Log that we've ran the MySQL command
    logger('[Revert] Reverted to old storagetier');

    # Touch the indication file
    system("touch $already_ran") == 0 and die "[Revert] [!] Failed to create reverted file: $!\n";

    exit;
}

# Collect top data
sub spawn_top {
    my ($killed_dir) = @_; 

    my $dying = "$killed_dir/top";
    my $top_dir = "$output_dir/top";
    my $top_log = sprintf "%s/%s", $top_dir, time;

    # Create output directory
    unless (-d $top_dir) {
        mkdir $top_dir or die "[top] [!] Failed to create $top_dir: $!\n";
    }   

    # Open my log file
    open my $top_handle, '>>', $top_log
      or die "[top] [!] Failed to open '$top_log'; $!\n";

    # Gracefully exit
    my $killed_me = sub {
        my ($filehandle, $log_file) = @_; 

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[top] [!] Failed to create dying file: $!\n";
        logger('[top] Received SIGTERM');

        # Close log handle
        close $top_handle;
        logger("[top] Closed log file '$top_log'");

        # Remove dying file
        unlink $dying or die "[top] [!] Failed to unlink '$dying': $!\n";
        logger('[top] Gracefully exited');

        exit;
    };  

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }   
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($top_handle, $top_log);
        }
    }   

    # Log that I've been spawned
    logger('[top] Collecting top data');
    logger("[top] Logging \`top -b -n1 -c -H\` to '$top_log'");

    # Every second execute top
    while () {
        my $timestamp = gen_timestamp;
    
        # Get top output
        my @top_out = `COLUMNS=300 top -b -n1 -c -H`;
        if ($? > 0) { die "[top] [!] Failed to execute top\n" }
    
        # Log the top output
        my $banner = banner($timestamp);
        print $top_handle $banner;
        print $top_handle @top_out;
    
        sleep 1;
    }

    exit;
}

# Collect vmstat output
sub spawn_vmstat {
    my ($killed_dir) = @_;

    my $dying      = "$killed_dir/vmstat";
    my $vmstat_dir = "$output_dir/vmstat";
    my $vmstat_out = sprintf "%s/%s", $vmstat_dir, time;

    # Create output directory
    unless (-d $vmstat_dir) {
        mkdir $vmstat_dir or die "[vmstat] [!] Failed to create dying file: $!\n";
    }

    # Open log file
    open my $vmstat_out_h, '>>', $vmstat_out
      or die "[vmstat] [!] Failed to open '$vmstat_out': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($out_file) = @_;

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[vmstat] [!] Failed to create dying file: $!\n";
        logger('[vmstat] Received SIGTERM');

        # Log where I wrote the data
        logger("[vmstat] vmstat output was written to '$out_file'");

        # Remove dying file
        unlink $dying or die "[vmstat] [!] Failed to unlink '$dying': $!\n";
        logger('[vmstat] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($vmstat_out);
        }
    }

    # Log that I'm executing vmstat
    logger('[vmstat] Collecting vmstat info');
    logger("[vmstat] Logging \`vmstat -S M 1\` to $vmstat_out");

    # Open my command pipe
    open my $vmstat_h, "vmstat -S M 1 |"
      or die "[vmstat] [!] Failed to open vmstat: $!\n";

    # Write command output to log file
    while (<$vmstat_h>) {
        my $timestamp = gen_timestamp;
        printf $vmstat_out_h "[%s] %s", $timestamp, $_;
    }

    exit;
}

# Collect `ps faux` output
sub spawn_ps_faux {
    my ($killed_dir) = @_;
    
    my $dying  = "$killed_dir/ps_faux";
    my $ps_dir = "$output_dir/ps_faux";
    my $ps_log = sprintf "%s/%s", $ps_dir, time;

    # Create my output directory
    unless (-d $ps_dir) {
        mkdir $ps_dir or die "[ps faux] [!] Failed to create '$ps_dir': $!\n";
    }

    # Open my log file
    open my $ps_handle, '>>', $ps_log
      or die "[ps faux] [!] Failed to open '$ps_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($ps_handle, $ps_log) = @_;

        # Indicate that I've died
        system("touch $dying") == 0 and die "[ps faux] [!] Failed to create dying file: $!\n";
        logger('[ps faux] Received SIGTERM');

        # Close my log file
        close $ps_handle;
        logger("[ps faux] Closed log file '$ps_log'");

        # Remove dying file
        unlink $dying or die "[ps faux] [!] Failed to unlink '$dying': $!\n";
        logger('[ps faux] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($ps_handle, $ps_log);
        }
    }

    # Log that I've been spawned
    logger('[ps faux] Collecting `ps faux` data');
    logger("[ps faux] Logging `ps faux` data to '$ps_log'");

    # Every second execute ps
    while () {
        my $timestamp = gen_timestamp;

        # Execute ps
        my @ps_out = `ps faux`;
        if ($? > 0) { die "[ps faux] [!] Failed to execute `ps faux`\n" }

        # Write ps output to log file
        my $banner = banner($timestamp);
        print $ps_handle $banner;
        print $ps_handle @ps_out;

        sleep 1;
    }

    exit;
}

# Record /proc/meminfo contents
sub spawn_proc_meminfo {
    my ($killed_dir) = @_;

    my $dying       = "$killed_dir/proc_meminfo";
    my $meminfo_dir = "$output_dir/proc_meminfo";
    my $meminfo_log = sprintf "%s/%s", $meminfo_dir, time;

    # Create my output directory
    unless (-d $meminfo_dir) {
        mkdir $meminfo_dir or die "[proc_meminfo] [!] Failed to create '$meminfo_dir'\n";
    }

    # Open my log file
    open my $meminfo_handle, '>>', $meminfo_log
      or die "[proc_meminfo] [!] Failed to open '$meminfo_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($meminfo_handle, $meminfo_log) = @_;

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[proc_meminfo] [!] Failed to create dying file: $!\n";
        logger('[proc_meminfo] Received SIGTERM');

        # Close my log file
        close $meminfo_handle;
        logger("[proc_meminfo] Closed log file '$meminfo_log'");

        # Remove dying file
        unlink $dying or die "[proc_meminfo] [!] Failed to unlink '$dying': $!\n";
        logger('[proc_meminfo] Gracefully exited');
        
        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($meminfo_handle, $meminfo_log);
        }
    }
    
    # Log that I've been spawned   
    logger('[proc_meminfo] Collecting /proc/meminfo data');
    logger("[proc_meminfo] Logging meminfo data to $meminfo_log");

    # Every second read /proc/meminfo and log it
    while () {
        my $timestamp = gen_timestamp;

        # Open /proc/meminfo
        open my $meminfo_fh, '<', '/proc/meminfo'
          or die "[proc_meminfo] [!] Failed to open '/proc/meminfo': $!\n";
        my @meminfo = <$meminfo_fh>;
        close $meminfo_fh;

        # Log /proc/meminfo
        my $banner = banner($timestamp);
        print $meminfo_handle $banner;
        print $meminfo_handle @meminfo;

        sleep 1;
    }

    exit;
}

# Record /proc/vmstat contents
sub spawn_proc_vmstat {
    my ($killed_dir) = @_;

    my $dying      = "$killed_dir/proc_vmstat";
    my $vmstat_dir = "$output_dir/proc_vmstat";
    my $vmstat_log = sprintf "%s/%s", $vmstat_dir, time;

    # Create output directory
    unless (-d $vmstat_dir) {
        mkdir $vmstat_dir or die "[proc_vmstat] [!] Failed to create '$vmstat_dir'\n";
    }

    # Open my log
    open my $vmstat_handle, '>>', $vmstat_log
      or die "[proc_vmstat] [!] Failed to open '$vmstat_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($vmstat_handle, $vmstat_log) = @_;

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[proc_vmstat] [!] Failed to create dying file: $!\n";
        logger('[proc_vmstat] Received SIGTERM');

        # Close my log
        close $vmstat_handle;
        logger("[proc_vmstat] Closed log file '$vmstat_log'");

        # Remove my dying file
        unlink $dying or die "[proc_vmstat] [!] Failed to unlink '$dying': $!\n";
        logger('[proc_vmstat] Gracefully exited');
        
        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($vmstat_handle, $vmstat_log);
        }
    }
    
    # Log that I've been spawned
    logger('[proc_vmstat] Collecting /proc/vmstat data');
    logger("[proc_vmstat] Logging vmstat data to $vmstat_log");

    # Every second read /proc/vmstat and log it
    while () {
        my $timestamp = gen_timestamp;

        # Open /proc/vmstat
        open my $vmstat_fh, '<', '/proc/vmstat'
          or die "[proc_vmstat] [!] Failed to open '/proc/vmstat': $!\n";
        my @vmstat = <$vmstat_fh>;
        close $vmstat_fh;

        # Log /proc/vmstat
        my $banner = banner($timestamp);
        print $vmstat_handle $banner;
        print $vmstat_handle @vmstat;

        sleep 1;
    }

    exit;
}

# Collect Gluster Performance values
sub spawn_gfs_perf {
    my ($killed_dir) = @_;

    my $dying      = "$killed_dir/gluster_perf";
    my $volume     = 'redacted'; ##CHANGE
    my $brick      = 'redacted'; ##CHANGE
    my $perf_dir   = "$output_dir/gluster_perf";
    my $perf_time  = sprintf "%s/%s", $perf_dir, time;
    my $read_perf  = "$perf_time/read-perf";
    my $write_perf = "$perf_time/write-perf";

    # Create output directory
    unless (-d $perf_dir) {
        mkdir $perf_dir or die "[Gluster Perf] [!] Failed to create '$perf_dir': $!\n";
    }

    # Create output directory for this run
    unless (-d $perf_time) {
        mkdir $perf_time or die "[Gluster Perf] [!] Failed to create '$perf_time': $!\n";
    }

    # Open my read log
    open my $read_perf_h, '>>', $read_perf
      or die "[Gluster Perf] [!] Failed to open '$read_perf': $!\n";

    # Open my write log
    open my $write_perf_h, '>>', $write_perf
      or die "[Gluster Perf] [!] Failed to open '$write_perf': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($read_h, $read, $write_h, $write) = @_;

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[Gluster Perf] [!] Failed to create dying file: $!\n";
        logger('[Gluster Perf] Received SIGTERM');

        # Close read log
        close $read_h;
        logger("[Gluster Perf] Closed log file '$read'");

        # Close write log
        close $write_h;
        logger("[Gluster Perf] Closed log file '$write'");

        # Remove dying file
        unlink $dying or die "[Gluster Perf] [!] Failed to unlink '$dying': $!\n";
        logger('[Gluster Perf] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($read_perf_h, $read_perf, $write_perf_h, $write_perf);
        }
    }

    # Log that I've been spawned
    logger('[Gluster Perf] Collecting gluster top read and write performance stats');
    logger("[Gluster Perf] Logging read performance to '$read_perf'");
    logger("[Gluster Perf] Logging write performance to '$write_perf'");

    # Every second record perf stats
    while () {
        my $timestamp = gen_timestamp;

        # Retrieve Gluster read perf
        my @read = `gluster volume top $volume read-perf bs 256 count 1 brick $brick list-cnt 10 2>/dev/null`;
        if ($? > 0) { die "[Gluster Perf] [!] Failed to retrieve read-perf\n" }
        
        # If we actually got something log it
        # No output can be returned if Gluster is busy
        if (@read) {
            my $banner = banner($timestamp);
            print $read_perf_h $banner;
            print $read_perf_h @read;
        }
        
        $timestamp = gen_timestamp;

        # Retrieve Gluster write perf
        my @write = `gluster volume top $volume write-perf bs 256 count 1 brick $brick list-cnt 10 2>/dev/null`;
        if ($? > 0) { die "[Gluster Perf] [!] Failed to retrieve write-perf\n" }

        # If we actually got something log it
        # No output can be returned if Gluster is busy
        if (@write) {
            my $banner = banner($timestamp);
            print $write_perf_h $banner;
            print $write_perf_h @read;
        }

        sleep 1;
    }

    exit;
}

# Collect iostat output
sub spawn_iostat {
    my ($killed_dir) = @_;

    my $dying      = "$killed_dir/iostat";
    my $disk       = '/dev/sdb'; ##CHANGE
    my $iostat_dir = "$output_dir/iostat";
    my $iostat_out = sprintf "%s/%s", $iostat_dir, time;

    # Create my output directory
    unless (-d $iostat_dir) {
        mkdir $iostat_dir or die "[iostat] [!] Failed to create '$iostat_dir'";
    }

    # Open my log file
    open my $iostat_out_h, '>>', $iostat_out
      or die "[iostat] [!] Failed to open '$iostat_out': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($out_file) = @_;

        # Indicate that I'm dying
        system("touch $dying") == 0 and die "[iostat] [!] Failed to create dying file: $!\n";
        logger('[iostat] Received SIGTERM');

        # Log where I logged to
        logger("[iostat] iostat output was written to '$out_file'");

        # Remove dying file
        unlink $dying or die "[iostat] [!] Failed to unlink '$dying': $!\n";
        logger('[iostat] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($iostat_out);
        }
    }

    # Log that I've been spawned
    logger('[iostat] Collecting iostat info');
    logger("[iostat] Logging \`iostat -c -d -x -t -m $disk 2\` to $iostat_out");

    # Open my command pipe
    open my $iostat_h, "iostat -c -d -x -t -m $disk 2 2>/dev/null |"
      or die "[iostat] [!] Failed to open iostat: $!\n";

    # Write command output to log
    while (<$iostat_h>) {
        print $iostat_out_h $_;
    }

    exit;
}

# Collect mpstat output
sub spawn_mpstat {
    my ($killed_dir) = @_;

    my $dying      = "$killed_dir/mpstat";
    my $mpstat_dir = "$output_dir/mpstat";
    my $mpstat_out = sprintf "%s/%s", $mpstat_dir, time;

    # Create my output directory
    unless (-d $mpstat_dir) {
        mkdir $mpstat_dir or die "[mpstat] [!] Failed to create dying file: $!\n";
    }

    # Open my log
    open my $mpstat_out_h, '>>', $mpstat_out
      or die "[mpstat] [!] Failed to open '$mpstat_out': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($out_file) = @_;

        # Indicate that I'm dying
        system("touch $dying") == 0 and die "[mpstat] [!] Failed to create dying file: $!\n";
        logger('[mpstat] Received SIGTERM');

        # Log where I logged to
        logger("[mpstat] mpstat output was written to '$out_file'");

        # Remove dying file
        unlink $dying or die "[mpstat] [!] Failed to unlink '$dying': $!\n";
        logger('[mpstat] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($mpstat_out);
        }
    }

    # Log that I've been spawned
    logger('[mpstat] Collecting mpstat info');
    logger("[mpstat] Logging \`mpstat -P ALL 2\` to $mpstat_out");
    
    # Open my command pipe
    open my $mpstat_h, "mpstat -P ALL 2 |"
      or die "[mpstat] [!] Failed to open mpstat: $!\n";

    # Write command output to log file
    while (<$mpstat_h>) {
        print $mpstat_out_h $_;
    }

    exit;
}

# Collect free output
sub spawn_free {
    my ($killed_dir) = @_;

    my $dying    = "$killed_dir/free";
    my $free_dir = "$output_dir/free";
    my $free_log = sprintf "%s/%s", $free_dir, time;

    # Create my output directory
    unless (-d $free_dir) {
        mkdir $free_dir or die "[free] [!] Failed to create '$free_dir': $!\n";
    }

    # Open my log file
    open my $free_h, '>>', $free_log
      or die "[free] [!] Failed to open '$free_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($log_h, $log) = @_;

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[free] [!] Failed to create dying file: $!\n";
        logger('[free] Received SIGTERM');

        # Close log file
        close $log_h;
        logger("[free] Closed log file '$log'");

        # Remove dying file
        unlink $dying or die "[free] [!] Failed to unlink '$dying': $!\n";
        logger('[free] Gracefully exited');

        exit
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
         $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($free_h, $free_log);
        }
    }

    # Log that I've been spawned
    logger('[free] Collecting free memory data');
    logger("[free] Logging free data to $free_log");

    # Every second execute free
    while () {
        my $timestamp = gen_timestamp;

        # Get free output
        my @free_out = `free -m`;
        if ($? > 0) { die "[free] [!] Failed to exec free\n" }

        # Log free output
        my $banner = banner($timestamp);
        print $free_h $banner;
        print $free_h @free_out;

        sleep 1;
    }

    exit;
}

# Collect Dell OMSA output
sub spawn_omsa {
    my ($killed_dir) = @_;

    my $dying           = "$killed_dir/omsa";
    my $controller_0    = 0; ##CHANGE
    my $omsa_dir        = "$output_dir/omsa";
    my $omsa_controller = sprintf "%s/%s.%i", $omsa_dir, 'controller', time;
    my $omsa_battery    = sprintf "%s/%s.%i", $omsa_dir, 'battery', time;
    my $started         = sprintf "%s/started", $omsa_dir;
    my $completed       = sprintf "%s/completed", $omsa_dir;

    # Create output directory
    unless (-d $omsa_dir) {
        mkdir $omsa_dir or die "[OMSA] [!] Failed to create '$omsa_dir': $!\n";
    }

    # Open controller log
    open my $controller_h, '>>', $omsa_controller
      or die "[OMSA] [!] Failed to open '$omsa_controller': $!\n";

    # Open battery log
    open my $battery_h, '>>', $omsa_battery
      or die "[OMSA] [!] Failed to open '$omsa_battery': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($completed) = @_ ;

        # Do nothing if still running
        if (-f $started) {
            return 0;
        }

        # Indicate that I've been killed
        system("touch $dying") == 0 and die "[OMSA] [!] Failed to create dying file: $!\n";
        logger('[OMSA] Received SIGTERM');

        # Remove the completed file
        if (-f $completed) {
            unlink $completed or die "[OMSA] [!] Failed to unlink '$completed': $!\n";
            logger('[OMSA] Removed completed flag');
        }

        # Remove the dying file
        unlink $dying or die "[OMSA] [!] Failed to unlink '$dying': $!\n";
        logger('[OMSA] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying or running omreport
    if (-f $dying) {
        $SIG{'TERM'} = 'IGNORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($completed);
        }
    }

    # Log that I've been spawned
    system("touch $started") == 0 and die "[OMSA] [!] Failed to create started file: $!\n";
    logger('[OMSA] Collecting OMSA stats');
    logger("[OMSA] Logging controller stats to '$omsa_controller'");
    logger("[OMSA] Logging controller stats to '$omsa_battery'");

    # Collect omreport data and then do nothing
    while () {
        # If I haven't completed yet, collect omreport data
        if (! -f $completed) {
            my $timestamp = gen_timestamp;

            # Get RAID controller 0 info
            my @out_controller_0 = `omreport storage controller controller=$controller_0`;
            if ($? > 0) { die "[OMSA] [!] Failed to retrieve controller=0 stats\n" };

            # Log RAID controller 0 output
            print  $controller_h "\n" . '=' x length($timestamp) . "\n";
            printf $controller_h "%s\n", $timestamp;
            print  $controller_h '=' x length($timestamp) . "\n";
            print  $controller_h "\n" . '=' x length($timestamp) . "\n";
            print  $controller_h "Controller 0\n";
            print  $controller_h '=' x length($timestamp) . "\n\n";
            print  $controller_h @out_controller_0;

            $timestamp = gen_timestamp;

            # Get RAID batteries info
            my @out_battery = `omreport storage battery`;
            if ($? > 0) { die "[OMSA] [!] Failed to retrieve battery stats\n" };

            # Log RAID batteries output
            print  $battery_h "\n" . '=' x length($timestamp) . "\n";
            printf $battery_h "%s\n", $timestamp;
            print  $battery_h '=' x length($timestamp) . "\n";
            print  $battery_h "\n" . '=' x length($timestamp) . "\n";
            print  $battery_h "Battery\n";
            print  $battery_h '=' x length($timestamp) . "\n\n";
            print  $battery_h @out_battery;

            # Touch the completed file
            system("touch $completed") == 0 and die "[OMSA] [!] Failed to create completed file: $!\n";
            logger("[OMSA] Completed OMSA Reports: '$omsa_controller' '$omsa_battery'");
            unlink $started or die "[OMSA] [!] Failed to unlink started file: $!\n";
        }
        # Do nothing if I've already ran
        else {
            sleep 1;
        }
    }

    exit;
}

sub spawn_sar {
    my ($killed_dir) = @_;

    my $dying   = "$killed_dir/sar";
    my $sar_dir = "$output_dir/sar";
    my $sar_cur = sprintf "%s/%s", $sar_dir, time;

    # Create my output directory
    unless (-d $sar_dir) {
        mkdir $sar_dir or die "[sar] [!] Failed to create '$sar_dir'";
    }

    # Create my current directory
    unless (-d $sar_cur) {
        mkdir $sar_cur or die "[sar] [!] Failed to create '$sar_cur'";
    }

    # `sar` commands to run in parallel, comment out as neccessary
    my %sars = (
      'b'     => 0, # Report I/O and transfer rate statistics.
      'B'     => 0, # Report paging statistics.
      'd'     => 0, # Report activity for each block device
      'n DEV' => 0, # Report network statistics.
      'P ALL' => 0, # Report  per-processor  statistics  for  the specified processor or processors.
      'q'     => 0, # Report queue length and load averages.
      'r'     => 0, # Report memory utilization statistics.
      'R'     => 0, # Report memory statistics.
      'S'     => 0, # Report swap space utilization statistics.
      'u ALL' => 0, # Report CPU utilization.
      'v'     => 0, # Report status of inode, file and other kernel tables.
      'w'     => 0, # Report task creation and system switching activity.
      'W'     => 0, # Report swapping statistics.
    );

    # Gracefully die
    my $killed_me = sub {
        my ($pids, $sar_out) = @_;

        # Indicate that I'm dying
        system("touch $dying") == 0 and die "[sar] [!] Failed to create dying file: $!\n";
        logger('[sar] Received SIGTERM');

        # Log where I logged to
        logger("[sar] sar output was written to '$sar_out'");

        # Collect the running sar procs
        my @running = ();
        for my $pid (keys %$pids) {
            push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
        }

        # Kill the running sar procs
        while(@running) {

            # Shouldn't have to do this, but checking again
            @running = ();
            for my $pid (keys %$pids) {
                push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
            }

            # Do the kill
            for my $pid (@running) {
                `kill $pid >/dev/null 2>/dev/null` if -d "/proc/$pid";
                pop @running;
            }

            # Recheck our running jobs
            @running = ();
            for my $pid ( keys %$pids) {
                push @running, $pids->{$pid} if -d "/proc/$pids->{$pid}";
            }

            # Pause to allow sars to die
            sleep .1;
        }

        # Remove dying file
        unlink $dying or die "[sar] [!] Failed to unlink '$dying': $!\n";
        logger('[sar] Gracefully exited');

        exit;
    };

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }
    else {
        $SIG{'TERM'} = sub {
            $killed_me->(\%sars, $sar_cur);
        }
    }

    # Log that I've been spawned
    logger('[sar] Collecting sar info');

    for my $sar (keys %sars) {
        # Fork the sar job
        if (!$sars{$sar}) {
            $sars{$sar} = fork // die "[sar] [!] Can't fork: $!\n";

            # We've forked
            unless ($sars{$sar}) {
                $| = 1;
                my $sar_log = $sar;
                $sar_log =~ s/\s/_/g;
                # Log where we are outputting to
                logger("[sar] Logging \`sar -$sar 1` to $sar_cur/$sar_log");
                
                # Open log handle
                open my $sar_h, '>', "$sar_cur/$sar_log"
                  or die "[sar] [!] Failed to open '$sar_cur/$sar_log': $!\n";
                
                # Open command pipe
                open my $sar_p, "sar -$sar 1|"
                  or die "[sar] [!] Failed to execute `sar -$sar 1`: $!\n";

                # Once job is started, change SIGTERM handling
                $SIG{'TERM'} = sub {
                    close $sar_h;
                    close $sar_p;
                    exit;
                };

                # Write command output to log file
                while (<$sar_p>) {
                    print $sar_h $_;
                }

                # Should never hit this but being safe
                close $sar_p;
                close $sar_h;
                exit;
            }
        }
    }

    # Sleep the sar parent until killed
    while () { sleep 1 }

    exit;
}

# Collect ps -eLF output
sub spawn_ps_eLF {
    my ($killed_dir) = @_;
    
    my $dying  = "$killed_dir/ps_-eLF";
    my $ps_dir = "$output_dir/ps_-eLF";
    my $ps_log = sprintf "%s/%s", $ps_dir, time;

    # Create my output directory
    unless (-d $ps_dir) {
        mkdir $ps_dir or die "[ps -eLF] [!] Failed to create '$ps_dir': $!\n";
    }    

    # Open my log file
    open my $ps_handle, '>>', $ps_log
      or die "[ps -eLF] [!] Failed to open '$ps_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($ps_handle, $ps_log) = @_;

        # Indicate that I've died
        system("touch $dying") == 0 and die "[ps -eLF] [!] Failed to create dying file: $!\n";
        logger('[ps -eLF] Received SIGTERM');

        # Close my log file
        close $ps_handle;
        logger("[ps -eLF] Closed log file '$ps_log'");

        # Remove dying file
        unlink $dying or die "[ps -eLF] [!] Failed to unlink '$dying': $!\n";
        logger('[ps -eLF] Gracefully exited');

        exit;
    };   

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }    
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($ps_handle, $ps_log);
        }
    }    

    # Log that I've been spawned
    logger('[ps -eLF] Collecting `ps -eLF` data');
    logger("[ps -eLF] Logging `ps -eLF` data to '$ps_log'");

    # Every second execute ps
    while () { 
        my $timestamp = gen_timestamp;

        # Execute ps
        my @ps_out = `ps -eLF`;
        if ($? > 0) { die "[ps -eLF] [!] Failed to execute `ps -eLF`\n" }

        # Write ps output to log file
        my $banner = banner($timestamp);
        print $ps_handle $banner;
        print $ps_handle @ps_out;

        sleep 1;
    }    

    exit;
}

# Collect lsof network output
sub spawn_lsof_network {
    my ($killed_dir) = @_;
    
    my $dying    = "$killed_dir/lsof_network";
    my $lsof_dir = "$output_dir/lsof_network";
    my $lsof_log = sprintf "%s/%s", $lsof_dir, time;

    # Create my output directory
    unless (-d $lsof_dir) {
        mkdir $lsof_dir or die "[lsof network] [!] Failed to create '$lsof_dir': $!\n";
    }    

    # Open my log file
    open my $lsof_handle, '>>', $lsof_log
      or die "[lsof network] [!] Failed to open '$lsof_log': $!\n";

    # Gracefully die
    my $killed_me = sub {
        my ($lsof_handle, $lsof_log) = @_;

        # Indicate that I've died
        system("touch $dying") == 0 and die "[lsof network] [!] Failed to create dying file: $!\n";
        logger('[lsof network] Received SIGTERM');

        # Close my log file
        close $lsof_handle;
        logger("[lsof network] Closed log file '$lsof_log'");

        # Remove dying file
        unlink $dying or die "[lsof] [!] Failed to unlink '$dying': $!\n";
        logger('[lsof network] Gracefully exited');

        exit;
    };   

    # Don't kill me if I'm dying
    if (-f $dying) {
        $SIG{'TERM'} = 'INGORE';
    }    
    else {
        $SIG{'TERM'} = sub {
            $killed_me->($lsof_handle, $lsof_log);
        }
    }    

    # Log that I've been spawned
    logger('[lsof] Collecting `lsof -i -n -P` data');
    logger("[lsof] Logging `lsof -i -n -P` data to '$lsof_log'");

    # Every second execute ps
    while () { 
        my $timestamp = gen_timestamp();

        # Execute ps
        my @lsof_out = `lsof -i -n -P`;
        if ($? > 0) { die "[lsof network] [!] Failed to execute `lsof -i -n -P`\n" }

        # Write ps output to log file
        my $banner = banner($timestamp);
        print $lsof_handle $banner;
        print $lsof_handle @lsof_out;

        sleep 1;
    }    

    exit;
}

exit 255;

