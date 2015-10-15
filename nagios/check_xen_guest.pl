#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_xen_guest
#: Version : 1.0
#: Path    : /usr/local/nagios/libexec/check_xen_guest.pl
#: Params  : Guest name-label
#: Desc    : Reports if guest is running

use strict;
use warnings;

use Getopt::Long;

# Show help if no arguments supplied
if ( ! @ARGV ) {
    help(0);
}

# Handle arguments
my %args;
GetOptions(
    'h|help'   => \$args{help},
    'n|name=s' => \$args{name}
) or help(1);

# Help me
if ($args{help}) {
    help(0);
}

# Main

if (!$args{name}) {
    printf "[!] Guest name not supplied.\n";
    exit 2;
}

my $prefix = 'OK';
my $exit_code = 0;

my $cur_state = get_state($args{name});

unless ( $cur_state =~ /running/ ) {
    $prefix = 'CRITICAL';
    $exit_code = 2;
}

printf "[%s] Guest '%s' is currently: %s\n", $prefix, $args{name}, $cur_state;
exit $exit_code;

# Subs

# Help
sub help {
    my ( $ec ) = @_;

    print <<EOH;
check_xen_guest.pl -- Reports if supplied guest is running

Usage: check_xen_guest.pl --name <name-label>

Parameters:
  -h|--help         Displays this message
  -n|--name         The name-label of the guest machine
EOH
    exit $ec;
}

# Extract Xen param value
sub extract_xen_info {
    my ( $xen_line ) = @_;

    # Strip new line characters from provided string
    $xen_line =~ s/(\r|\n)//g;
    # Extract only the value from the raw `xe cli` output
    $xen_line =~ s/^\S+\s\(\s\S{2}\)\s+:\s(.*)$/$1/;

    # Return extracted value
    return "$xen_line";
}

sub get_state {
    my ( $name ) = @_;

    # Get raw `xe cli` output of physical size of provided SR UUID
    my $state = `sudo xe vm-list params=power-state name-label=$name 2>&1`;
    if ( $? > 0) {
        chomp $state;
        printf "[!] Failed to retrieve vm-list: %s\n", $state;
        exit 2;
    }

    return extract_xen_info($state);
}
