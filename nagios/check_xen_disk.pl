#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_xen_disk
#: Version : 1.0
#: Path    : /usr/local/nagios/libexec/check_xen_disk.pl
#: Params  : Storage repository, warning and critical thresholds
#: Desc    : Reports Storage Repository usage

use strict;
use warnings;

use Switch;
use Getopt::Long;

# Show help if no arguments supplied
if ( ! @ARGV ) {
    help(0);
}

# Handle arguments
my %args;
GetOptions(
    'h|help'       => \$args{help},
    'n|name=s'     => \$args{name},
    'U|uuid=s'     => \$args{uuid},
    'w|warning=i'  => \$args{warning},
    'c|critical=i' => \$args{critical},
    'm|unit=s'     => \$args{unit}
) or help(1);

# Help me
if ($args{help}) {
    help(0);
}

# Main
if (!$args{name} or !$args{uuid} or !$args{critical} or !$args{warning} or !$args{unit}) {
    die "Required arguments missing";
}

my $size = get_size($args{uuid});
my $util = get_util($args{uuid});

switch ($args{unit}) {
    case m/^b(tye)?$/i {
        output($args{name}, $size, $util, 'B',  1024 ** 0, $args{warning}, $args{critical})
    }
    case m/^k(b)?$/i {
        output($args{name}, $size, $util, 'KB', 1024 ** 1, $args{warning}, $args{critical})
    }
    case m/^m(b)?$/i {
        output($args{name}, $size, $util, 'MB', 1024 ** 2, $args{warning}, $args{critical})
    }
    case m/^g(b)?$/i {
        output($args{name}, $size, $util, 'GB', 1024 ** 3, $args{warning}, $args{critical})
    }
    case m/^t(b)?$/i {
        output($args{name}, $size, $util, 'TB', 1024 ** 4, $args{warning}, $args{critical})
    }
    else { die "Invalid unit: '$args{unit}'" }
}

# Subs

sub help {
    my ( $ec ) = @_;
    print <<EOH;
check_xen_disk.pl -- Reports disk usage for XenServer Storage Repository

Usage: check_xen_disk.pl --name <SR name> --uuid <SR UUID> --warning <warn percent> --critical <crit percent> --unit [B|KB|MB|GB|TB]

Parameters:
  -h|--help         Displays this message
  -n|--name         Name of the Storage Repository
  -U|--uuid         UUID of the XenServer SR
  -w|--warning      Percentage used of SR to trigger warning
  -c|--critical     Percentage used of SR to trigger critical
  -m|--unit         Unit of measurement for output [B|KB|MB|GB|TB]
EOH
    exit $ec;
}

# Output
sub output {
    my ( $name, $size, $util, $unit, $unit_int, $warning, $critical ) = @_;

    my $per = int( 100 - ( ( $util / $size ) * 100 ) );
    my $free = int( ( $size - $util ) / $unit_int );
    my $usage = int( $util / $unit_int );

    $warning = int( ( ( $size * (100 - $warning) ) / $unit_int ) / 100 );
    $critical = int( ( ( $size * (100 - $critical) ) / $unit_int ) / 100 );

    my $status = 'OK';
    my $exit_code = 0;
    if ( $usage > $critical ) {
        $status = 'Critical';
        $exit_code = 2;
    }
    elsif ( $usage > $warning ) {
        $status = 'Warning';
        $exit_code = 1;
    }
    
    printf "Disk %s - free space: %s %s %s (%s%%) | %s=%s%s;%s;%s\n",
      $status, $name, $free, $unit, $per, $name, $usage, $unit, $warning, $critical;
    exit $exit_code;
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

sub get_size {
    my ( $uuid ) = @_;
    # Get raw `xe cli` output of physical size of provided SR UUID
    my $size = `sudo xe sr-list params=physical-size uuid=$uuid`;
    if ( $? > 0) {
        die '[!] Failed to retrieve physical-size';
    }
    $size = extract_xen_info($size);

    return $size;
}

sub get_util {
    my ( $uuid ) = @_;
    # Get raw `xe cli` output of physical utilisation of provided SR UUID
    my $util = `sudo xe sr-list params=physical-utilisation uuid=$uuid`;
    if ( $? > 0) {
        die '[!] Failed to retrieve physical-utilisation';
    }
    $util = extract_xen_info($util);

    return $util;
}
