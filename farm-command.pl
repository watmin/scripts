#!/usr/bin/perl
#: Author  : John Shields <jshields@alertlogic.com>
#: Name    : farm-command.pl
#: Version : 1.8.4
#: Path    : $ENV{'HOME'}/bin/farm-command
#: Params  : --do-it 'echo foo'
#: Options : -h|--help, -v|--verbose, -m|--max <jobs>, -t|--timeout <seconds>
#:         : -f|file <hosts-file>, -p|--pattern <hosts-pattern>,
#:         : -s|--ssh 'ssh command', -j|--json, -c|--scp 'scp command',
#:         : -l|--local '/local/scp/path', -r|--remote '/remote/scp/path',
#:         : -F|--altfile <host-list>, -C|--command <command-file>,
#:         : -S|--ssh-slave 'ssh command', --slave-cmd 'execute on connect',
#:         : -L|--log '/path/to/log', --no-profile
#: Desc    : Runs supplied command on target hosts

$0 = 'farm-command';

use strict;
use warnings;

use Time::HiRes qw/time sleep/;
use POSIX;
use IPC::Open3;
use IO::Select;
use JSON::XS;
use IO::Socket::UNIX;
use Getopt::Long qw/:config no_ignore_case/;

@ARGV or help();

Getopt::Long::Configure('bundling');

my %opts = ('verbose' => 0);
GetOptions(
    'h|help'        => \$opts{'help'},
    'v|verbose'     => sub { $opts{'verbose'}++ },
    'm|max=i'       => \$opts{'max'},
    't|timeout=i'   => \$opts{'timeout'},
    'f|file=s'      => \$opts{'file'},
    'p|pattern=s'   => \$opts{'pattern'},
    's|ssh=s'       => \$opts{'ssh'},
    'S|ssh-slave=s' => \$opts{'ssh-slave'},
    'slave-cmd=s'   => \$opts{'slave-cmd'},
    'j|json'        => \$opts{'json'},
    'c|scp=s'       => \$opts{'scp'},
    'l|local=s'     => \$opts{'local'},
    'r|remote=s'    => \$opts{'remote'},
    'F|altfile=s'   => \$opts{'altfile'},
    'C|command=s'   => \$opts{'command'},
    'L|log=s'       => \$opts{'log'},
    'no-profile'    => \$opts{'no-profile'},
    'do-it'         => \$opts{'do-it'},
) or die "Invalid option. See $0 --help\n";

$opts{'help'} and help();

if (!($opts{'file'} and $opts{'pattern'}) and !$opts{'altfile'}) {
    die "Failed to provide host target list\n";
}
elsif ($opts{'file'} and !-f $opts{'file'}) {
    die "The host file '$opts{'file'}' is not found\n";
}
elsif ($opts{'altfile'} and !-f $opts{'altfile'}) {
    die "The host file '$opts{'altfile'}' is not found\n";
}

my $master_pid = $$;

my $command = join ' ', @ARGV;
my $audit_command = "'$command'";

if ($opts{'command'}) {
    open my $command_h, '<', $opts{'command'}
      or die "Failed to open '$opts{'command'}': $!\n";

    my %fcvars;
    $command = '';
    while (my $line =<$command_h>) {
        if ($line =~ m/^fcvar: /) {
            chomp $line;
            if ($line =~ m/^fcvar: (\S+)\s=\s(.*)/) {
                my ($var, $local_command) = ($1, $2);
                my ($output, $exit_code)  = run_command($local_command);

                if ($exit_code == 0) {
                    $fcvars{$var} = $output;
                }
                else {
                    die "Local command '$local_command' did not exit 0\n";
                }
            }
        }
        else {
            $command .= $line;
        }
    }

    close $command_h
      or die "Failed to close '$opts{'command'}': $!\n";

    for my $var (keys %fcvars) {
        $command =~ s/\{\{#$var\}\}/$fcvars{$var}/g;
    }

    $audit_command = "commands provided by '$opts{'command'}'";
}

if (!$opts{'do-it'}) {
    die "Failed to say the magic words\n";
}

if (!$opts{'local'} and $opts{'remote'} or
    !$opts{'remote'} and $opts{'local'})
{
    die "Failed to provide both local path and remote destintion for scp\n";
}

if ($opts{'local'} and !-e $opts{'local'}) {
    die "Local scp path does not exist\n";
}

my $now = strftime('%Y-%m-%d_%H-%M-%S', localtime);
my $log = "$now-farm.log";
if ($opts{'log'}) {
    $log = $opts{'log'};
}

if ($opts{'json'} and !$opts{'log'}) {
    $log = "$now-farm.json";
}

my $log_socket = "/tmp/farm-command.$$.${\time}.queue";
$SIG{'INT'}  = sub { sig_int($log_socket); };
$SIG{'TERM'} = sub { sig_term($log_socket); };

open my $log_h, '>', $log or die "Failed to open '$log': $!\n";
print "Logging to $log\n";

my $host_file = $opts{'file'};
my $pattern   = $opts{'pattern'};
my $alt_file  = $opts{'altfile'};
my $ssh       = $opts{'ssh'}       || 'ssh';
my $slave     = $opts{'ssh-slave'} || 'ssh';
my $scp       = $opts{'scp'}       || 'scp';
my $timeout   = $opts{'timeout'}   || 10;
my $local     = $opts{'local'};
my $remote    = $opts{'remote'};
my @hosts     = get_hosts($host_file, $pattern, $alt_file);
my $max_jobs  = $opts{'max'} || int(scalar @hosts / 100) || 1;
my %jobs      = map { $_ => { 'pid' => 0 } } 1 .. $max_jobs;
my $done      = 0;

my $audit_hosts;
if ($opts{'altfile'}) {
    $audit_hosts = "hosts provided by '$opts{'altfile'}'";
}
else {
    $audit_hosts = "hosts matching '$pattern' within '$host_file'";
}

$SIG{'CHLD'} = sub { sig_chld(); };

my ($logger, $log_pass) = make_logger($log_socket);
my $logger_pid          = fork;

if ($logger_pid) {
    close $logger;
    close $log_h;
}
else {
    process_logs($logger);
}

my $started = time;

write_log(
    'host'    => 'farm-command',
    'pid'     => $$,
    'job'     => 0,
    'message' => "Running $audit_command on $audit_hosts",
    'start'   => $started,
    'end'     => undef,
    'exit'    => undef,
) unless $opts{'json'};

while () {
    my $job = get_job();

    if ($done and get_active_jobs() == 0) {
        last;
    }

    if ($job) {
        my $host = shift @hosts;
        if (!$host) {
            if (!$done) {
                $done = 1;
                print "Processed all hosts, waiting for active jobs to end\n"
                  if $opts{'verbose'} >= 2;
            }
            next;
        }

        print "Spawning job '$job' to work on '$host'\n"
          if $opts{'verbose'} >= 1;

        my $pid = fork;
        if ($pid) {
            set_job($job, $host, $pid);
        }
        else {
            $SIG{'TERM'} = $SIG{'INT'} = 'DEFAULT';
            write_log(
                'host'    => $host,
                'pid'     => $$,
                'job'     => $job,
                'message' => 'Beginning',
                'start'   => time,
                'end'     => undef,
                'exit'    => undef,
            ) unless $opts{'json'};

            my $exit_code = do_job($job, $host, $command) // 255;
            exit $exit_code;
        }
    }
}

my $end      = time;
my $finished = sprintf "Completed run in %0.4f seconds", $end - $started;

write_log(
    'host'    => 'farm-command',
    'pid'     => $$,
    'job'     => 0,
    'message' => $finished,
    'start'   => $started,
    'end'     => $end,
    'exit'    => undef,
) unless $opts{'json'};

close_logger($log_socket);
waitpid($logger_pid, 0);
unlink $log_socket
  or warn "Failed to remove queue socket '$log_socket': $!\n";

exit;

sub help {
    print <<"EOH";
$0 -- This script will run the supplied command on all hosts

Usage: $0 --do-it [-v[vv]] [-m <number>] echo foo

Options:
  -h,--help             Shows this output
  -v,--verbose          Increases the verbosity, up to 3
  -m,--max              Defines the max concurrent jobs
  -t,--timeout          SSH ConnectTimeout value
  -f,--file             Hosts file to read from
  -p,--pattern          Pattern to use to extract hosts from hosts file
  -s,--ssh              SSH command to use for each ssh execution
  -j,--json             Writes JSON objects to the log file for each host
  -c,--scp              SCP command to use for each scp execution
  -l,--local            The local path to use for scp
  -r,--remote           The remote path to use for scp
  -F,--altfile          File containing hosts, one per line
  -C,--command          File containing commands to run on remote host
  -S,--ssh-slave        SSH command to use for each ssh slave connection
  -L,--log              The file to log to
  --slave-cmd           Executable to be ran when opening slave connection

Notes:
  - You must supply a hostfile for the script to execute

   - You can define an /etc/hosts style file with -f and the patten with -p
    - You can flip the format to connect to IPs and match on hostname if DNS
      is not configured or not parsing /etc/hosts
    - The hosts file can also include the hostname twice to perform a DNS
      lookup instead of using /etc/hosts or an IP address

  - You can alternately use a host list with -F that contains one host per line.

  - By default, the number of concurrent jobs is the number of found hosts
    divded by 100. This can be modified with the -m switch

  - The default timeout is 10 seconds.

  - This script will always log to your current directory, however you can get
    additional information displayed with -v, -vv, -vvv
    - The log file is \$TIMESTAMP-farm.log
    - You can use -j,--json to output JSON for each connection
      - The json log file is \$TIMESTAMP-farm.json
    - You can change the file's path with -L,--log

  - The --ssh command overrides the default ssh command 'ssh' with your defined
    command. You can use --ssh 'sudo -u user ssh -i /path/to/key -l remoteuser'
    to run ssh in a sudo'd context.
    - If using sudo, ensure you have ran sudo atleast once in your current
      session so your forked processes do not fail or hang.

  - The --scp command overrides the default scp command 'scp'.
    - If the scp fails, the job is killed wth the scp output

  - The -S,--slave command changes the slave ssh binary from 'ssh' to your
    defined value

  - The --slave-cmd switch appends an executable path to the slave ssh connection
    - This prevents the /etc/profile file from being loaded on bash login sessions:
      --slave-cmd "'[ -x /bin/bash ] && /bin/bash --login --noprofile'"

  - The option --no-profile sets the following:
    - If remote \$SHELL is '/bin/bash':
      --slave-cmd '/bin/bash --login --noprofile --norc'
    - If remote \$SHELL is '/bin/ksh':
      --slave-cmd '/bin/ksh'
    -S 'ssh -t'
    The switch -S is preserved if already defined

John Shields <jshields\@alertlogic.com> - 2016
EOH

    exit 1;
}

sub get_hosts {
    my ($hosts_file, $pattern, $altfile) = @_;
    my @hosts;

    if (!$altfile) {
        open my $hosts_h, '<', $hosts_file
          or die "Failed to open '$hosts_file': $!\n";

        while (my $line = <$hosts_h>) {
            chomp $line;
            next if $line =~ /^\s*#/;

            if ($line =~ m/$pattern/) {
                push @hosts, (split /\s+/, $line)[1];
            }
        }

        close $hosts_h or die "Failed to close '$hosts_file': $!\n";
    }
    else {
        open my $alt_h, '<', $altfile
          or die "Failed to open '$altfile': $!\n";

        while (my $line = <$alt_h>) {
            chomp $line;
            next if $line =~ /^\s*#/;

            push @hosts, $line;
        }

        close $alt_h or die "Failed to close '$altfile': $!\n";
    }

    return @hosts;
}

sub run_command {
    my ($command, $input) = @_;

    my ($exit_code, $done);
    my $_sig_chld = sub {
        while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
            $exit_code = $? >> 8;
            $done = 1;
        }
    };
    $SIG{'CHLD'} = sub { $_sig_chld->(); };

    my $select = IO::Select->new;
    my $pid = open3(\*CHILD_IN, \*CHILD_OUT, \*CHILD_ERR, $command);

    print CHILD_IN $input if $input;
    close CHILD_IN or die "Failed to close ssh STDIN\n: $!\n";

    $select->add(\*CHILD_OUT);
    $select->add(\*CHILD_ERR);

    my $output = '';
    my @handles;

    while (@handles = $select->can_read) {
        for my $handle (@handles) {
            my $buffer = '';
            my $bytes;

            if ($handle eq \*CHILD_ERR) {
                $bytes = sysread(*CHILD_ERR, $buffer, 4096);
                $output .= $buffer if $buffer;
            }
            else {
                $bytes = sysread(*CHILD_OUT, $buffer, 4096);
                $output .= $buffer if $buffer;
            }

            $select->remove($handle) unless $bytes;
        }
    }

    while (!$done) {}

    close CHILD_OUT or die "Failed to close stdout: $!\n";
    close CHILD_ERR or die "Failed to close stderr: $!\n";

    return ($output, $exit_code);
}

sub make_ssh_master {
    my ($target, $socket) = @_;

    $0 = "farm-command job ssh control master";

    my $port = 22;
    if ($target =~ m/\.elb\./) {
        $port = 2222;
    }

    my $ssh_opts = "-o ConnectTimeout=$timeout";
    $ssh_opts .= " -o StrictHostKeyChecking=no";
    $ssh_opts .= " -o Port=$port";

    my $command = "$ssh -tt $ssh_opts -M -S $socket $target";

    print "Creating a master connection with '$command'\n"
      if $opts{'verbose'} >= 2;

    my ($output, $exit_code) = run_command($command);

    return;
}

sub check_ssh_master {
    my ($socket, $target) = @_;

    my $command = "$ssh -O check -S $socket $target";

    print "Checking the master connection with '$command'\n"
      if $opts{'verbose'} >= 3;

    my ($output, $exit_code) = run_command($command);

    if ($output =~ /Master running/) {
        return 1;
    }

    return;
}

sub kill_ssh_master {
    my ($socket, $target) = @_;

    my $command = "$ssh -O exit -S $socket $target";

    print "Killing master connection with '$command'\n"
      if $opts{'verbose'} >= 2;

    my ($output, $exit_code) = ('', 0);

    while ($output !~ /No such file/) {
        ($output, $exit_code) = run_command($command);
    }

    return;
}

sub ssh_command {
    my ($target, $socket, $command) = @_;

    my $timeout = "-o ConnectTimeout=$timeout";

    if ($opts{'no-profile'}) {
        my $shell_check = "$ssh $timeout -q -S $socket $target";

        print "Creating a slave connection with '$shell_check'\n"
          if $opts{'verbose'} >= 2;

        my ($shell_out, $exit) = run_command($shell_check, 'echo $SHELL');

        if ($shell_out =~ m|/bin/bash|) {
            $opts{'slave-cmd'} = '/bin/bash --login --noprofile --norc';
            $slave             = 'ssh -t' unless defined $slave;
        }
        elsif ($shell_out =~ m|/bin/ksh|) {
            $opts{'slave-cmd'} = '/bin/ksh';
            $slave             = 'ssh -t' unless defined $slave;
        }
    }

    my $ssh_command = "$slave $timeout -q -S $socket $target";

    if ($opts{'slave-cmd'}) {
        $ssh_command = "$ssh_command $opts{'slave-cmd'}";
    }

    print "Creating a slave connection with '$ssh_command'\n"
      if $opts{'verbose'} >= 2;

    my ($output, $exit_code) = run_command($ssh_command, $command);

    return ($output, $exit_code);
}

sub write_log {
    my (%log) = @_;

    $log{'exit'} = 255 unless defined $log{'exit'};

    my $client = make_log_client($log_socket);
    my $json   = JSON::XS->new->encode(\%log);

    print $client "${log_pass}${json}\n";

    if ($!{EAGAIN}) {
        write_log(%log);
    }

    close $client;

    return;
}

sub get_job {
    for my $job (keys %jobs) {
        if ($jobs{$job}{'pid'} == 0) {
            return $job;
        }
    }

    return;
}

sub get_active_jobs {
    my $active_jobs = 0;

    for my $job (keys %jobs) {
        $active_jobs++ if $jobs{$job}{'pid'};
    }

    return $active_jobs;
}

sub do_job {
    my ($job, $host, $command) = @_;

    $0 = "farm-command job $job host $host";

    my ($output, $exit_code, $timedout, $failed);
    my $socket = "/tmp/$host.$$.${\time}.master";

    my $start = time;

    my $master = fork;
    if (!$master) {
        make_ssh_master($host, $socket);
        exit;
    }
    else {
        while () {
            if (time > $start + $timeout) {
                $timedout = 1;
                last;
            }

            if (waitpid($master, WNOHANG)) {
                $failed = 1;
                last;
            }

            next unless (check_ssh_master($socket, $host));

            if ($local and $remote) {
                ($output, $exit_code) = scp_to_host($host, $socket);
                if ($exit_code) {
                    $output = "Failed to scp: $output";
                    last;
                }
            }

            ($output, $exit_code) = ssh_command($host, $socket, $command);
            if ($opts{'verbose'} >= 3) {
                (my $stdout = $output) =~ s/^/\[Job: $job Host: $host\] /gms;
                print $stdout;
            }

            last;
        }
    }

    my $end = time;

    kill_ssh_master($socket, $host);

    write_log(
        'host'    => $host,
        'pid'     => $$,
        'job'     => $job,
        'message' => get_job_output($output, $failed, $timedout),
        'start'   => $start,
        'end'     => $end,
        'exit'    => $exit_code,
    );

    return $exit_code;
}

sub get_job_output {
    my ($output, $failed, $timedout) = @_;

    if ($output) {
        if (!$opts{'json'}) {
            $output =~ s/\r|\n/ ; /gms;
        }
    }
    elsif ($failed) {
        $output = "Failed to create SSH tunnel";
    }
    elsif ($timedout) {
        $output = "Failed to create SSH tunnel - timeout";
    }
    else {
        $output = "No output";
    }

    return $output;
}

sub set_job {
    my ($job, $host, $pid) = @_;

    $jobs{$job}{'pid'}   = $pid;
    $jobs{$job}{'host'}  = $host;
    $jobs{$job}{'start'} = time;

    return;
}

sub reset_job {
    my ($job) = @_;

    $jobs{$job}{'pid'}   = 0;
    $jobs{$job}{'host'}  = undef;
    $jobs{$job}{'start'} = undef;

    return;
}

sub sig_chld {
    my $pid;

    while (($pid = waitpid(-1, WNOHANG)) > 0) {
        my $exit = $? >> 8;
        my $end = time;

        for my $job (keys %jobs) {
            if ($jobs{$job}{'pid'} == $pid) {
                my $run = sprintf("%0.4f", $end - $jobs{$job}{'start'});
                my $message = "Completed in $run seconds. Exited $exit";
                write_log(
                    'host'    => $jobs{$job}{'host'},
                    'pid'     => $pid,
                    'job'     => $job,
                    'message' => $message,
                    'start'   => $jobs{$job}{'start'},
                    'end'     => $end,
                    'exit'    => $exit,
                ) unless $opts{'json'};
                reset_job($job);
            }
        }
    }

    return;
}

sub sig_int {
    my ($log_socket) = @_;

    return unless $$ == $master_pid;

    fear_the_reaper();
    close_logger($log_socket);

    unlink $log_socket;

    exit;
}

sub sig_term {
    my ($log_socket) = @_;

    return unless $$ == $master_pid;

    fear_the_reaper();
    close_logger($log_socket);

    unlink $log_socket;

    exit;
}

sub fear_the_reaper {
    for my $job (keys %jobs) {
        if ($jobs{$job}{'pid'}) {
            my $alive;
            {
                no warnings 'uninitialized';
                $alive = kill 'SIGZERO' => $jobs{$job}{'pid'};
            }

            if ($alive) {
                $SIG{'TERM'} = 'IGNORE';
                {
                    no warnings 'uninitialized';
                    my $killed = kill 'TERM' => $jobs{$job}{'pid'};
                    $killed and reset_job($job);
                }
                $SIG{'TERM'} = sub { sig_term($log_socket); };
            }
        }
    }

    my $kill_em;
    for my $job (keys %jobs) {
        if ($jobs{$job}{'pid'}) {
            $kill_em = 1;
            last;
        }
    }

    if ($kill_em) {
        fear_the_reaper();
    }

    return;
}

sub make_logger {
    my ($socket) = @_;

    my $server = IO::Socket::UNIX->new(
        'Type'   => SOCK_STREAM,
        'Local'  => $socket,
        'Listen' => 1024,
        'Proto'  => 0,
    ) or die "Failed to create server: $!\n";

    my @chars = ("A".."Z", "a".."z");
    my $pass;
    $pass .= $chars[rand @chars] for 1..8;

    return ($server, $pass);
}

sub close_logger {
    my ($socket) = @_;

    my $client = make_log_client($socket);
    print $client "${log_pass}exit\n";

    if ($!{EAGAIN}) {
        close_logger($socket);
    }

    close $client;

    return;
}

sub make_log_client {
    my ($socket) = @_;

    my $client = IO::Socket::UNIX->new(
        'Type'  => SOCK_STREAM,
        'Peer'  => $socket,
        'Proto' => 0,
    );

    return $client;
}

sub process_logs {
    my ($server) = @_;

    $0 = "farm-command log queue";

    while () {
        my $client = $server->accept;

        if ($client) {
            chomp(my $payload = <$client>);
            $payload =~ m/(.{8})(.*)/;
            my ($pass, $message) = ($1, $2);

            next unless $pass and $pass eq $log_pass;

            if ($message eq 'exit') {
                close $server;
                last;
            }
            elsif (!$opts{'json'}) {
                my $log = JSON::XS->new->decode($message);
                my $timestamp = strftime('%Y-%m-%d %H:%M:%S', localtime);

                printf $log_h "[%s] [Job:%s PID:%s] %s - %s\n", $timestamp,
                  $log->{'job'}, $log->{'pid'}, $log->{'host'},
                  $log->{'message'}
            }
            else {
                printf $log_h "%s\n", $message;
            }
        }
    }

    exit;
}

sub scp_to_host {
    my ($host, $socket) = @_;

    my $scp_opts = "-o ConnectTimeout=$timeout";
    $scp_opts .= " -o ControlPath=$socket";

    my $command = "$scp -r $scp_opts $local $host:$remote";

    print "Creating a scp slave connection with '$command'\n"
      if $opts{'verbose'} >= 2;

    return run_command($command);
}

