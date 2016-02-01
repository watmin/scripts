#!/usr/bin/perl
#: Author  : John Shields <jshields@alertlogic.com>
#: Name    : s
#: Version : 1.0.1
#: Path    : /usr/local/bin/s
#: Params  : See --help
#: Desc    : SSH wrapper with logging
#: Date    : 2016-01-31 16:15 CST

use strict;
use warnings;

use Expect;
use File::Spec;
use IPC::Open3;
use POSIX qw/strftime/;
use Time::HiRes qw/gettimeofday/;
use Getopt::Long qw/:config no_ignore_case/;

require IO::Stty; # Expect needs this

@ARGV or help();

# Make sure we are sudo'ing
my $luser = $ENV{'SUDO_USER'};
$luser or die "Not ran from sudo\n";

# Keep a copy for logging
my @orig_argv = @ARGV;

my %args;
my @cli_opts;
GetOptions(
    'h|help'        => \$args{'help'},
    'p|port=i'      => \$args{'port'},
    'l|user=s'      => \$args{'user'},
    'i=s'           => \$args{'key'},
    'o=s@'          => \@cli_opts,
    'root'          => \$args{'root'},
    'f|file=s'      => \$args{'file'},
    'd|debug'       => \$args{'debug'},
    't=i'           => \$args{'timeout'},
    'interpreter=s' => \$args{'interpreter'},
) or die "Invalid option. See ${\File::Spec->rel2abs($0)} --help\n";

$args{'help'} and help();

my $rhost = shift;
$rhost or die "Failed to provide hostname\n";

my $ssh_bin = '/usr/bin/ssh';
my $script_bin = '/usr/bin/script';

my $is_elb;
my $dport = '22';
if ($rhost =~ /\.elb\./ix) {
    $dport = '2222';
    $is_elb = 1;
}
my $interpreter_heredoc = "__shields__$luser${\time}$$";

sanity_checks();

my ( $ruser, $rport, $rkey, @ssh_opts ) = prep_ssh( $luser, $dport, \%args, \@cli_opts );

my ( $master_log, $master_log_h, $audit_log, $audit_log_h ) = prep_logging( $luser, $rhost );

write_log( $master_log_h, "%s, INFO, %s, %s, %s\n",
  $luser, File::Spec->rel2abs($0), join( ' ', @orig_argv ), $audit_log );
close $master_log_h;

if ( !$args{'root'} and ( @ARGV or -p STDIN or $args{'file'} ) ) {
    my $input;
    $input = 'STDIN' if -p *STDIN;
    $input = '@ARGV' if @ARGV;
    $input = "file (${\File::Spec->rel2abs($args{'file'})})" if $args{'file'};

    write_log( $audit_log_h, "%s is running commands from %s\n", $luser, $input );

    my $command = get_command( \%args, $audit_log_h );

    my @pipe_opts = ( # SSH options to make it quiet
        '-o' => 'LogLevel=QUIET',
        '-o' => 'RequestTTY=yes',
        '-q',
    );

    my ( $ssh_pid, $ssh_in, $ssh_out, $response );
    my $ssh_conn = join ' ', $ssh_bin, @ssh_opts, @pipe_opts, $rhost;
    print "SSH connection is '$ssh_conn'\n" if $args{'debug'};
    $ssh_pid = open3( $ssh_in, $ssh_out, '>&STDERR', $ssh_conn )
      or die "Failed to open '$ssh_bin': $!\n";

    print $ssh_in $command;
    while ( $response = <$ssh_out> ) {
        write_log( $audit_log_h, "[output] %s", $response );
        print "$response";
    }

    waitpid( $ssh_pid, 0 );
    my $exit_code = ( $? >> 8 ) ;

    $ssh_in and close($ssh_in);
    $ssh_out and close($ssh_out);

    write_log( $audit_log_h, "Exit: %d\n", $exit_code );

    close $audit_log_h;

    exit $exit_code;
}
else {
    close $audit_log_h; # /usr/bin/script is going to log for us

    my $ssh_conn = join ' ', $ssh_bin, @ssh_opts, '-tt', $rhost;
    $ssh_conn = "\"$ssh_conn\"";
    print "SSH connection is '$ssh_conn'\n" if $args{'debug'};

    my @script_opts = ( '-f', '-q', '-c' );

    if ( $args{'root'} ) {
        my $script_comm = join ' ', $script_bin, @script_opts, "$ssh_conn", $audit_log;
        print "script command is '$script_comm'\n" if $args{'debug'};

        my $expect = Expect->spawn($script_comm) or die "Failed to spawn with expect: $!\n";
        $expect->raw_pty(1);

        # Handle window resizes
        $expect->slave->clone_winsize_from(\*STDIN);
        my $sigwinch = sub {
            $expect->slave->clone_winsize_from(\*STDIN);
            kill WINCH => $expect->pid if $expect->pid;
        };
        $SIG{'WINCH'} = sub { $sigwinch->(); };

        get_root( $expect, \%args );
    }
    else {
        my $script_comm = join ' ', $script_bin, @script_opts, "$ssh_conn", $audit_log;
        print "script command is '$script_comm'\n" if $args{'debug'};
        system($script_comm);
    }

    exit;
}

die "This shouldn't have happened.\n";

sub help {
    print <<'EOH';
s -- SSH auditor/wrapper/tool/connector

Usage: s [ options ] hostname [ commands to run ]

s can be provided commands to be ran on the remote server using the following:
  - STDIN : Commands read from an incoming pipe
  - @ARGV : Commands supplied via additional arguments
  - File  : Commands supplied via an input file
  Note: You can only supply one input stream.

If no command streams are provided, then an SSH login session will be created

Options:
  -h,--help             Shows this output
  -p,--port             Sets the SSH port (Defaults 22, 2222 for AWS ELB)
  -l,--user             User to connect to on remote server
  -i,--key              Key to use when connecting
  -o                    Sets SSH options, can be provided multiple times
  --root                Attempts to get root using password list
  -f,--file             Reads in commands from supplied file
  -t                    Sets the SSH connection timeout, (Default 30)
  -d,--debug            Prints the full command line for SSH and script
  --interpreter         Reads in file supplied by --file into the interpreter

Notes:
  Valid interpreters are 'sh', 'bash', 'perl', 'python'. Using --interpreter
    will create a heredoc of the file and pipe it into the interpreter on
    the remote server

  You cannot get exit codes to correctly come out of script therefor you
  cannot rely on them when using --file and --root in batch loops

  When using STDIN for commands they must be finite, the script will wait
  for an EOF from STDIN before doing the SSH connection

John Shields - AlertLogic - 2016
EOH
    exit 1;
}

sub sanitize {
    my ( $regex, $input ) = @_;

    die "Invalid input:\n\n$input\n\n" if $input !~ /^$regex$/x;

    return $input;
}

sub sanity_checks {
    my $input_check = 0;
    $input_check ++ if @ARGV;
    $input_check ++ if -p STDIN;
    $input_check ++ if $args{'file'};

    die "Too many inputs\n" if $input_check > 1;

    # Check rhost for validness
    my $host_check;
    $host_check .= qr/([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])/;
    $host_check .= qr/(\.([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]{0,61}[a-zA-Z0-9]))*/;
    sanitize( $host_check, $rhost );

    if ( $args{'file'} ) {
        die "Command file not found\n" if !-f $args{'file'};
        die "Command file not readable\n" if !-r $args{'file'};
    }
    if ( $args{'user'} ) {
        sanitize( qr/([a-z_][a-z0-9_]{0,30})/, $args{'user'} );
    }
    if ( $args{'port'} ) {
        sanitize( qr/\d+/, $args{'port'} );
    }
    if ( $args{'key'} ) {
        sanitize( qr#(/)?([^/\0]+(/)?)+#, $args{'key'} );
        die "SSH key not found\n" if !-f $args{'key'};
        die "SSH key not readable\n" if !-r $args{'key'};
    }
    if ( $args{'interpreter'} ) {
        sanitize( qr/sh|bash|perl|python/, $args{'interpreter'} );
    }

    return;
}

sub write_log {
    my ( $file_h, $format, @strings ) = @_;

    fileno $file_h or die "The variable \$file_h, '$file_h', is not a file handle\n";
    $format or die "Failed to provide logging format string\n";
    @strings or die "Failed to provide strings to use for format string\n";

    $format = "[%s.%06d] $format";
    my @times = gettimeofday;

    printf $file_h $format, strftime( "%F %T", localtime( $times[0] ) ), $times[1], @strings;

    return;
}

sub prep_ssh {
    my ( $luser, $dport, $opts_r, $cli_opts_r ) = @_;

    my %opts = %{ $opts_r };
    my @cli_opts = @{ $cli_opts_r };

    my $ruser = $opts{'user'} || $luser;
    my $rport = $opts{'port'} || $dport;
    my $rkey  = $opts{'key'};

    my @opts = (
        '-o' => "User=$ruser",
        '-o' => "Port=$rport",
    );

    if ($is_elb) {
        push @opts, ( '-o' => 'ServerAliveInterval=15' );
    }

    if ( $opts{'timeout'} ) {
        push @opts, ( '-o' => 'ConnectTimeout=' . sanitize( qr/\d+/, $opts{'timeout'} ) );
    }
    else {
        push @opts, ( '-o' => 'ConnectTimeout=30' );
    }

    if (@cli_opts) {
        for my $opt (@cli_opts) {
            push @opts, ( '-o' => sanitize( qr/[A-Z][a-zA-Z]+=[a-zA-Z0-9:\-]+/, $opt ) );
        }
    }

    if ($rkey) {
        push @opts, (
            '-o' => "IdentityFile=$rkey",
            '-o' => 'IdentitiesOnly=yes',
            '-o' => 'GSSAPIAuthentication=no',
            '-o' => 'PasswordAuthentication=no',
        );
    }
    else {
        push @opts, (
            '-o' => 'PubkeyAuthentication=no',
        );
    }

    return ( $ruser, $rport, $rkey, @opts );
}

sub prep_logging {
    my ( $user, $host ) = @_;

    my $epoch = time;
    my $masterlog = '/tmp/ssh-logs/master.log';
    my $logfile = "/tmp/ssh-logs/$rhost/$luser.$epoch.log";

    if (!-d '/tmp/') {
        mkdir '/tmp' or die "Failed to create '/tmp/' $!\n";
    }
    if (!-d '/tmp/ssh-logs') {
        mkdir '/tmp/ssh-logs' or die "Failed to create '/tmp/ssh-logs': $!\n";
    }
    if (!-d "/tmp/ssh-logs/$host") {
        mkdir "/tmp/ssh-logs/$host" or die "Failed to create 'tmp/ssh-logs/$host': $!\n";
    }

    open my $master_h, '>>', $masterlog or die "Failed to open '$masterlog': $!\n";

    open my $logfile_h, '>>', $logfile or die "Failed to open '$logfile': $!\n";

    return ( $masterlog, $master_h, $logfile, $logfile_h );
}

sub get_command {
    my ( $opts_r, $audit_log_h ) = @_;

    my %opts = %{ $opts_r };

    if ( !$opts{'root'} and !$audit_log_h ) {
        die "Failed to provide audit_log file handle\n";
    }

    open my $stdin, '<&', *STDIN;

    if ( $opts{'file'} ) {
        open $stdin, '<', $opts{'file'}
          or die "Failed to open '$opts{'file'}': $!\n";
    }

    if (@ARGV) {
        my $comm_str = join ' ', @ARGV, "\n";
        open $stdin, '<', \$comm_str;
    }

    my ( $line, @stdin_lines );

    if ( $opts{'interpreter'} ) {
        my $start = "cat <<'$interpreter_heredoc' | $opts{'interpreter'}\n";
        $audit_log_h and write_log( $audit_log_h, "[input] %s", $start );
        push @stdin_lines, $start;
    }

    while ( $line = <$stdin> ) {
        $audit_log_h and write_log( $audit_log_h, "[input] %s", $line );
        push @stdin_lines, $line;
    }

    if ( $opts{'interpreter'} ) {
        my $end = "$interpreter_heredoc\n";
        $audit_log_h and write_log( $audit_log_h, "[input] %s", $end );
        push @stdin_lines, $end;
    }

    my $command= join '', @stdin_lines, "exit \$?\n"; # Have to force an exit

    return $command;
}

sub get_root {
    my ( $expect, $opts_r ) = @_;

    my %opts = %{ $opts_r };

    my $timeout = 3;
    $expect->expect( $timeout, [ '[#>$] ' => sub { $expect->send("sudo su -\n"); } ] );

    my @passwords = get_passwords();
    my $password;

  SUDO:
    $password = shift @passwords;
    $expect->expect(
        $timeout,
        [ 'password for .*?:' => sub { # Enter the sudo password
                $expect->send("$password\n");
                exp_continue;
            }
        ],
        [ 'Sorry, try again.' => sub {
                goto SUDO;
            }
        ],
        [ 'attempts' => sub { # Fail to our current shell if we don't have a command file
                die "Failed to get root\n" if $opts{'file'};
                $expect->interact;
                exit;
            }
        ],
        [ '[#>:] $' => sub { # Run our command file if we have one
                if ( $opts{'file'} ) {
                    my $command = get_command(\%opts);
                    $command = "$command\nexit \$?\n"; # Force an exit from root
                    $expect->send("$command\n");
                }
            }
        ],
    );

    $expect->interact;

    return;
}

# Something to get the current passwords from
sub get_passwords {
    my @passwords;

    my $counter = 0;
    open my $pass_h, '<', '/tmp/passwords'
      or die "Failed to open '/tmp/passwords': $!\n";
    while (<$pass_h>) {
        chomp;
        last if $counter > 3;
        $counter++;
        push @passwords, $_;
    }
    close $pass_h;

    return @passwords;
}

