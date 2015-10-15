#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_sendgrid_dns.pl
#: Version : 1.1
#: Path    : /usr/lib/nagios/plugins/check_sendgrid_dns
#: Params  : None
#: Desc    : Checks if smtp.sendgrid.net is resolving to their known IPs
#: Changes :
#: 1.1     : Contructing new array from provided ranges/ips

use strict;
use warnings;

use Socket;
use Net::hostent;
use List::Util;

# Valid IP addresses provided by SendGrid
my @defined_ips = (
    '198.37.144.0/24' ,
    '208.43.76.146',
    '208.43.76.147',
    '5.153.47.202',
    '5.153.47.203',
    '158.85.10.138',
    '108.168.190.108',
);

my @valid_ips = ();
for my $ip (@defined_ips) {
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

my $hostname = 'smtp.sendgrid.net';
my @ip_addrs = ();

my $hostent;
if ($hostent = gethostbyname($hostname)) {
    my $addr_ref = $hostent->addr_list;
    @ip_addrs = map { inet_ntoa($_) } @$addr_ref;
}
else {
    print "[Critical] Failed to retieve host information \n";
    exit 2;
}

my $failure = 0;
my $failmsg = '';
my $success = 0;
my $output = '';

# Iterate over each IP we got
for my $ip (@ip_addrs) {
    $success = 0;

    # Iterate over our valid IPs
    for my $valid (@valid_ips) {
    next if $success;

        if ( List::Util::first { $_ eq $ip } @valid_ips ) {
            $success = 1;
            $output .= sprintf "%s, ", $ip;
            next;
        }
        else {
            $failure = 1;
        }

    }

    $failmsg .= sprintf "%s is not valid, ", $ip
      if $failure;
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

