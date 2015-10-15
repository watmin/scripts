#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : collect-logs.pl
#: Version : 1.0.0
#: Path    : /opt/sv/bin/collect-logs
#: Params  : see --help
#: Desc    : Collects Linux diagnositics

use strict;
use warnings;

use Getopt::Long;
use Sys::Hostname;
use POSIX qw/strftime/;
use POSIX qw/:sys_wait_h/;
use IO::Handle;

if (!@ARGV) {
    help();
    exit;
}

use constant OUTPUT => {
    FINITE => 1,
    STREAM => 2,
};

my $log_dir = "/opt/sv/logs/collect-logs";
if (!-d $log_dir) {
    mkdir $log_dir or die "Failed to create '$log_dir': $!\n";
}

my $cur_dir = sprintf "$log_dir/%s", (strftime "%Y-%m-%d_%H.%M.%S", localtime) ;
if (!-d $cur_dir) {
    mkdir $cur_dir or die "Failed to create '$cur_dir': $!\n";
}

my @com_netstat      = ( OUTPUT->{FINITE}, 'sudo netstat -nap' );
my @com_top          = ( OUTPUT->{FINITE}, 'COLUMNS=300 sudo top -b -n1 -c -H') ;
my @com_free         = ( OUTPUT->{FINITE}, 'sudo free -m' );
my @com_vmstat       = ( OUTPUT->{STREAM}, 'sudo vmstat -S M 1' );
my @com_ps_faux      = ( OUTPUT->{FINITE}, 'sudo ps faux' );
my @com_ps_eLF       = ( OUTPUT->{FINITE}, 'sudo ps -eLF' );
my @com_lsof_network = ( OUTPUT->{FINITE}, 'sudo lsof -i -n -P' );
my @com_sar          = ( OUTPUT->{STREAM}, 'sudo sar -%s 1' );
my @com_iostat       = ( OUTPUT->{STREAM}, 'sudo iostat -c -d -x -t -m %s 1' );
my @com_mpstat       = ( OUTPUT->{STREAM}, 'sudo mpstat -P %s 1' );
my @com_proc_meminfo = ( OUTPUT->{FINITE}, 'sudo cat /proc/meminfo' );
my @com_proc_vmstat  = ( OUTPUT->{FINITE}, 'sudo cat /proc/vmstat' );

my %args;
GetOptions(
    'h|help'       => \$args{'help'},
    'netstat'      => \$args{'netstat'},
    'top'          => \$args{'top'},
    'free'         => \$args{'free'},
    'vmstat'       => \$args{'vmstat'},
    'ps-faux'      => \$args{'ps-faux'},
    'ps-eLF'       => \$args{'ps-eLF'},
    'lsof_network' => \$args{'lsof_network'},
    'sar=s@'       => \$args{'sar'},
    'iostat=s'     => \$args{'iostat'},
    'mpstat=s'     => \$args{'mpstat'},
    'proc_meminfo' => \$args{'proc_meminfo'},
    'proc_vmstat'  => \$args{'proc_vmstat'},
    'stream=s@'    => \$args{'stream'},
    'finite=s@'    => \$args{'finite'},
) or die "See $0 -h\n";

if ($args{'help'}) {
    help();
    exit;
}

collect_logs(%args);
exit;

sub help {
    print <<EOH;
collect-logs.pl - Executes commands in parallel logging all output.

Usage: collects-logs --finite 'sudo netstat -nap' --stream 'sudo vmstat -S M 1'

Options:
  -h, --help      Shows this output
  --stream        Executes the streaming output command
  --finite        Executes the finite output command, repeatedly

Predefined commands:
  --netstat       Executes 'sudo netstat -nap'
  --top           Executes 'COLUMNS=300 sudo top -b -n1 -c -H'
  --free          Executes 'sudo free -m'
  --vmstat        Executes 'sudo vmstat -S M 1'
  --ps-faux       Executes 'sudo ps faux'
  --ps-eLF        Executes 'sudo ps -eLF'
  --losf_network  Executes 'sudo lsof -i -n -P'
  --sar           Executes 'sudo sar -%s 1' requires metric
  --iostat        Executes 'sudo iostat -c -d -x -t -m %s 1', requires disk
  --mpstat        Executes 'sudo mpstat -P %s 1' requires CPU
  --proc_meminfo  Executes 'sudo cat /proc/meminfo'
  --proc_vmstat   Executes 'sudo cat /proc/vmstat'

Notes:
  --stream, --finite can be passed multiple times resulting in a command
    array to be ran in parallel

  --sar can be passed multiple times e.g.:
    collect-logs --sar a --sar b --sar 'n DEV'

  --iostat, --mpstat can be passed 'ALL' to record all disks, CPUs

  All logs will be written to '/opt/sv/logs/collect-logs'. The log name
    will be the command and time it was ran.

EOH
    return;
}

sub collect_logs {
    my %args = @_;

    my @commands = build_command_array(%args);
    for my $command (@commands) {
        my $pid = fork;
        next if $pid;

        spawn_command($command);
    }
    while () {
        my $kid = waitpid(-1, WNOHANG);
        last if $kid > 0;
    }
    print "leaving collect_logs\n";

    return;
}

sub spawn_command {
    my ($command) = @_;

    ( my $log_name = $command->{'command'} ) =~ s/[^a-zA-Z0-9\.\-_]/./g;

    if ($command->{'output'} == OUTPUT->{FINITE}) {
        spawn_finite($command->{'command'}, "$cur_dir/$log_name.log");
    }
    elsif ($command->{'output'} == OUTPUT->{STREAM}) {
        spawn_stream($command->{'command'}, "$cur_dir/$log_name.log");
    }
    else {
        warn "Somehow got an unknown output '$command->{'output'}'";
    }

    exit;
}

sub spawn_finite {
    my ($command, $log) = @_;

    open my $log_h, '>>', $log
      or die "Failed to open '$log': $!\n";

    $log_h->autoflush(1);

    while () {
        open my $pipe, "$command|"
          or die "Failed to open command pipe: $!\n";
        
        my @lines = <$pipe>;
        close $pipe;

        print $log_h get_banner();
        print $log_h @lines;

        sleep 1;
    }

    close $log_h;

    return;
}

sub spawn_stream {
    my ($command, $log) = @_;

    open my $log_h, '>>', $log
      or die "Failed to open '$log'; $!\n";

    $log_h->autoflush(1);

    open my $pipe, "$command|"
      or die "Failed to open command pipe: $!\n";

    my $line;
    while ( $line = <$pipe> ) {
        printf $log_h "[%s] %s", get_timestamp(), $line;
    }

    close $pipe;
    close $log_h;

    return;
}

sub build_command_array {
    my %args = @_;

    for my $check (keys %args) {
        if (!defined $args{$check}) {
            delete $args{$check};
        }
    }

    my @sars = process_sar($args{'sar'});
    delete $args{'sar'};

    my @streams = process_stream($args{'stream'});
    delete $args{'stream'};
    
    my @finites = process_finite($args{'finite'});
    delete $args{'finite'};

    my @commands;
    for my $arg ( keys %args ) {
        if    ( $arg eq 'netstat' )      { push @commands, set_command( @com_netstat ) }
        elsif ( $arg eq 'top' )          { push @commands, set_command( @com_top ) }
        elsif ( $arg eq 'free' )         { push @commands, set_command( @com_free ) }
        elsif ( $arg eq 'vmstat' )       { push @commands, set_command( @com_vmstat ) }
        elsif ( $arg eq 'ps_faux' )      { push @commands, set_command( @com_ps_faux ) }
        elsif ( $arg eq 'ps_eLF' )       { push @commands, set_command( @com_ps_eLF ) }
        elsif ( $arg eq 'lsof_network' ) { push @commands, set_command( @com_lsof_network ) }
        elsif ( $arg eq 'proc_meminfo')  { push @commands, set_command( @com_proc_meminfo ) }
        elsif ( $arg eq 'proc_vmstat' )  { push @commands, set_command( @com_proc_vmstat ) }
        elsif ( $arg eq 'iostat' )       { push @commands, build_command( @com_iostat, $args{$arg} ) }
        elsif ( $arg eq 'mpstat' )       { push @commands, build_command( @com_mpstat, $args{$arg} ) }
        else                             { warn "Somehow got this arg '$arg'" }
    }

    return ( @sars, @streams, @finites, @commands );
}

sub set_command {
    my ( $output, $command ) = @_;

    return { 'output' => $output, 'command' => $command };
}

sub build_command {
    my ( $output, $command, @args ) = @_;

    $command = sprintf $command, @args;

    return set_command($output, $command);
}

sub process_sar {
    my ($sars) = @_;

    my @commands;
    for my $sar (@{$sars}) {
        push @commands, build_command(@com_sar, $sar);
    }

    return @commands;
}

sub process_stream {
    my ($streams) = @_;

    my @commands;
    for my $stream (@{$streams}) {
        push @commands, set_command(OUTPUT->{STREAM}, $stream);
    }

    return @commands;
}

sub process_finite {
    my ($finites) = @_;

    my @commands;
    for my $finite (@{$finites}) {
        push @commands, set_command(OUTPUT->{FINITE}, $finite);
    }

    return @commands;
}

sub get_timestamp {
    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", localtime;

    return $timestamp;
}

sub get_banner {
    my $timestamp = get_timestamp();

    my $equals = '=' x length($timestamp);

    my $lines  = sprintf "\n%s\n", $equals;
    $lines .= $timestamp;
    $lines .= sprintf "\n%s\n\n", $equals;

    return $lines;
}

