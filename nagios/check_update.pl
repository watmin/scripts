#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_update.pl
#: Version : 1.0
#: Path    : /usr/local/nagios/libexec/check_update
#: Params  : None
#: Desc    : Checks if system was upgraded wtih yum within the last 30 days

use strict;
use warnings;

my $warn_secs = 2592000; # 30 days
my $crit_secs = 3456000; # 40 days

my $yum_history = 'sudo yum history 2>&1';
my @history = `$yum_history`;

if ($?) {
    printf "[!] Failed to retrieve yum history: %s", join "", @history;
    exit 2;
}

my @updates = grep /\s+U\s+\||\s+Update\s+\|/, @history;

my $raw_update = $updates[0];
my @split_raw = split /\|/, $raw_update;

my $last_update = $split_raw[2];
$last_update =~ s/(^\s+|\s{2,})//g;

my $epoch = `date +%s -d '$last_update'`;

my $cur_time = time;

my $diff = $cur_time - $epoch;

if ( $diff > $crit_secs ) {
    printf "[Critical] LAST UPDATE OVER 40 DAYS AGO: %s\n", $last_update;
    exit 2;
}
elsif ( $diff > $warn_secs ) {
    printf "[Warning] Last updates applied over 30 days ago: %s\n", $last_update;
    exit 1;
}
else {
    printf "[OK] Last updates applied within the last 30 days: %s\n", $last_update;
    exit 0;
}
