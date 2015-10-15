#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_domain_expire.pl
#: Version : 1.0
#: Path    : /usr/lib/nagios/plugins/check_domain_expire.pl
#: Params  : domain name, warning and critical in days
#: Desc    : Reports if target domain is expiriring soon

use strict;
use warnings;

use Getopt::Long;
use Date::Parse;
use Date::Format;

# Script vars
my $interval = 86400; # 1 day
my $whois_bin = '/usr/bin/whois';

# Help if no args
if (!@ARGV) { help(0) }

# Handle arguments
my %args;
GetOptions(
    'h|help'       => \$args{help},
    'D|domain=s'   => \$args{domain},
    'W|warning=i'  => \$args{warn},
    'C|critical=i' => \$args{crit}
) or help(1);

if ($args{help}) { help(0) }

# Main
if (!$args{domain}) {
    die "[!] Domain not supplied.\n";
}
elsif ( ($args{warn} and !$args{crit}) or (!$args{warn} and $args{crit}) ) {
    die "[!] Cannot supply only one threshold\n";
}

my $exit_code = 0;
my $prefix = 'OK';
my $cur_time = time;

my $expire = get_expire($args{domain});
my $diff = $expire - $cur_time;
my $days = int( $diff / $interval );

# Build result
if ( $args{warn} and $args{crit} ) {
    if ( $days < $args{crit}) {
        $exit_code = 2;
        $prefix = 'Critical';
    }
    elsif ( $days < $args{warn} ) {
        $exit_code = 1;
        $prefix = 'Warning';
    }
}

# Print result
printf "[%s] %s expires on %s (%s days)\n",
  $prefix, $args{domain}, time2str( '%c', $expire ), $days;
exit $exit_code;

# Subs

# Help
sub help {
    my ( $ec ) = @_;
    printf <<EOH;
check_domain_expire.pl -- Reports expiration date for target domain

Usage: check_domain_expire.pl --domain <domain.com> [--warning <#days> --critical <#days>]

Parameters:
  -h|--help         Displays this message
  -D|--domain       Target domain

Options:
  -W|--warning      Number of days to trigger a warning
  -C|--critical     Number of days to trigger a critical

EOH
    exit $ec;
}

# Return expiration date in epoch
sub get_expire {
    my ( $domain ) = @_;
    
    my @whois = `$whois_bin $domain`;
    if ($?) {
        print "[!] whois failed: @whois";
        exit 3;
    }
    my @expiry = grep /(Registration Expiration Date|Expiry date|Domain Expiration Date)/, @whois;
    chomp ( my $expiration = $expiry[0] );
    my @result = split /:\s+/, $expiration;

    return str2time($result[1]);
}
