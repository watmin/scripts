#!/usr/bin/perl
# nagios: -epn
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : check_sv_dns.pl
#: Version : 1.0
#: Path    : /usr/lib/nagios64/plugins/check_sv_dns
#: Params  : -H,--host [hostname] -i,--ips [list,of,known,ips]
#: Desc    : Checks if provided hostname resolves to a known IP

use strict;
use warnings;

use Socket;
use Net::hostent;
use List::Util;
use Getopt::Long qw/:config no_ignore_case/;

@ARGV or help();

my %args;
GetOptions(
    'h|help'   => \$args{'help'},
    'H|host=s' => \$args{'host'},
    'i|ips=s'  => \$args{'ips'},
) or die "Invalid options. See $0 --help\n";

$args{'help'} and help();

if ( !$args{'host'} and !$args{'ips'} ) {
    die "Failed to provide required arguments. See $0 --help\n";
}

my @known_ips = split /,/, $args{'ips'};

my @valid_ips;
for my $ip (@known_ips) {
    # Process class C ranges
    if ($ip =~ m|/24|) {
        my $class_c = $ip;
        $class_c =~ s|/24||;
        $class_c =~ s/^((\d{1,3}\.){3}).*/$1/;
        for my $fourth (0..255) {
            push @valid_ips, "$class_c" . "$fourth";
        }
    }
    else {
        push @valid_ips, $ip;
    }
}

my $hostname = $args{'host'};
my @ip_addrs;

my $hostent;
if ($hostent = gethostbyname($hostname)) {
    my $addr_ref = $hostent->addr_list;
    @ip_addrs = map { inet_ntoa($_) } @{ $addr_ref };
}
else {
    print "[Critical] Failed to retieve host information \n";
    exit 2;
}

my $failure;
my $failmsg;
my $success;
my $output;

# Iterate over each IP we got
for my $ip (@ip_addrs) {
    $success = 0;

    # Iterate over our valid IPs
    for my $valid (@valid_ips) {
        $success and next;
        if ( List::Util::first { $_ eq $ip } @valid_ips ) {
            $success = 1;
            $output .= sprintf "%s, ", $ip;
            next;
        }
        else {
            $failure = 1;
        }
    }

    $failure and $failmsg .= sprintf "[Unknown] %s, ", $ip;
}

# Nagios output
if ($failure) {
    $failmsg =~ s/, $//;
    printf "DNS CRITICAL: %s resolves to %s\n", $hostname, $failmsg;
    exit 2;
}
else {
    $output =~ s/, $//;
    printf "DNS OK: %s resolves to %s\n", $hostname, $output;
    exit 0;
}

sub help {
    print <<EOH;
check_sv_dns.pl - Resolves hostname and reports IPs returned

Usage: check_sv_dns -H www.smartvault.com -i 72.250.195.37,72.250.195.38

Arguments:
  -H,--host             The hostname to resolve
  -i,--ips              The expected IP addresses

Options:
  -h,--help             Shows this output

Notes:
  The -i,--ips argument can take multiple IP addresses in a comma separated
  list. If the host resolves to any of the IPs within the list it will be
  considered a success.
  
  The -i,--ips argument can also take an IP address ending in /24 to build
  an array of all IP addreses within the subnet
  
  Ex:

  check_sv_dns -H smtp.sendgrid.net -i 198.37.144.0/24,208.43.76.146,\\
    208.43.76.147,5.153.47.202,5.153.47.203,158.85.10.138,108.168.190.108
EOH
    exit;
}

