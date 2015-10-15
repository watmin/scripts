#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : check_lsi_raid.pl
#: Version : 1.0
#: Path    : /usr/local/nagios/libexec/check_lsi_raid
#: Params  : --adapter <int> --vdisk <int>
#: Desc    : Retrieve RAID status for given RAID controller and disk device

use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case);

my $MegaCLI = 'sudo /opt/MegaRAID/MegaCli/MegaCli64';

if (!@ARGV) { help(0) }

my %args;
GetOptions(
    'h|help'    => \$args{help},
    'adapter=i' => \$args{adapter},
    'vdisk=i'   => \$args{vdisk},
) or help(1);

if ($args{help}) { help(0) }

if (!defined($args{adapter}) or !defined($args{vdisk})) {
    die "Must provide both adapter and disk divice\n";
}
my @state = `$MegaCLI -LDInfo -L$args{vdisk} -a$args{adapter} -NoLog`;
@state = grep {!/^\s*$/} @state;
@state = grep {!/^Default/} @state;
@state = grep {!/^(Adapter|Virtual)/} @state;
my @bad = grep {/error|degraded|fail/i} @state;

if (@bad) {
    chomp @bad;
    my $bad_line = join '; ', @bad;
    chomp @state;
    my $state_line = join '\\n', @state;
    printf '%s\n%s', $bad_line, $state_line;
    exit 2;
}
else {
    chomp @state;
    my $state_line = join '\\n', @state;
    printf 'RAID has no problems\n%s', $state_line;
    exit 0;
}

sub help {
    my ($exit_code) = @_;

    print <<EOH;
  check_lsi_raid -- Retrieves RAID state for given controller and disk device

Parameters:
  --adapter           RAID controller to check
  --vdisk             Disk device to check

  Both --adapater and --vdisk are required

Options:
  -h|--help           Shows this output

EOH

    exit $exit_code;
}

