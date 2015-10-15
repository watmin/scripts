#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : check_lsi_bbu.pl
#: Version : 1.0
#: Path    : /usr/local/nagios/libexec/check_lsi_raid
#: Params  : --adapter <int>
#: Desc    : Retrieve BBU status for given RAID controller

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case);

my $MegaCLI = 'sudo /opt/MegaRAID/MegaCli/MegaCli64';

if (!@ARGV) { help(0) }

my %args;
GetOptions(
    'h|help'    => \$args{help},
    'adapter=i' => \$args{adapter},
) or help(1);

if ($args{help}) { help(0) }

if (!defined($args{adapter})) {
    die "Must provide an adapter\n";
}


my @raw_info = `$MegaCLI -AdpBbuCmd -GetBbuStatus -a$args{adapter} -NoLog`;

chomp (my ($raw_state) = grep {/^Battery State/} @raw_info);
my @split_state = split /\s*:\s+/, $raw_state;
my $state = $split_state[1];

my @info;

my ($voltage) = grep {/^Volt/} @raw_info;
push @info, $voltage;

my ($temperature) = grep {/^Temp/} @raw_info;
push @info, $temperature;

push @info, $raw_state;

my ($charge) = grep {/^\s{2}Charg/} @raw_info;
$charge =~ s/^\s+//;
$charge =~ s/\s+(?=:)//;
push @info, $charge;

chomp @info;
my $info_line = join '\\n', @info;

if ($state !~ /Optimal/) {
    printf 'BBU is %s\n%s', $state, $info_line;
    exit 2;
}
else {
    printf 'BBU is %s\n%s', $state, $info_line;
    exit 0;
}

sub help {
    my ($exit_code) = @_;

    print <<EOH;
  check_lsi_bbu -- Retrieve BBU status for given RAID controller

Parameters:
  --adapter           RAID controller to check

Options:
  -h|--help           Shows this output

EOH

    exit $exit_code;
}

