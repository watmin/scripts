#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_svsmtp.pl
#: Version : 1.0
#: Path    : /usr/local/nagios/plugins/check_svsmtp
#: Params  : None
#: Desc    : Checks to see if SMTP is working

use strict;
use warnings;

use Mail::POP3Client;
use Email::Simple;
use Date::Format;

# Script variables
my $indicator = 'some_moderately_unique_string';
my $epoch = 0;
my $diff = 0;
my $exit_code = 255;
my $warn = 60 * 10;
my $crit = 60 * 15;

# Create POP3 object
my $pop = new Mail::POP3Client(
    USER        => 'your@email_account.biz',
    PASSWORD    => '_y0ur3mal3pas$wo7d',
    HOST        => 'pop3.your.isp',
    PORT        => 995,
    USESSL      => 1
);

# Iterate over our inbox
my $skip_flag = 0;
for ( my $inbox_handle = $pop->Count ; $inbox_handle > 0 ; $inbox_handle-- ) {
    my $headers = join( "\n", $pop->Head($inbox_handle) );
    my $email = Email::Simple->new($headers);
    my @subject = $email->header('Subject');
    if ( $subject[0] =~ /^\Q${indicator}\E/ ) {
        unless ( $skip_flag == 1 ) {
            # Skip older messages that could be in the inbox
            $skip_flag = 1;

            # Get our timestamps
            my $cur_time = time;
            my @epoch_split = split / /, $subject[0];
            chomp ( $epoch = $epoch_split[1] );

            # Get our freshness
            $diff = $cur_time - $epoch;

            # Determine Nagios exit
            if ( $diff > $crit ) {
            	$exit_code = 2;
            }
            elsif ( $diff > $warn ) {
               $exit_code = 1; 
            }
            elsif ( $diff < $warn ) {
                $exit_code = 0;
            }
        }
    }
    $pop->Delete($inbox_handle);
}
$pop->Close;

# Nagios output
if ( $exit_code == 0 ) {
    printf "[OK] Message received within the last 10 minutes :: %s (%s seconds ago)\n", time2str( "%c", $epoch ), $diff;
    exit $exit_code;
}
elsif ( $exit_code == 1 ) { 
    printf "[Warning] Message received over 10 minutes ago :: %s (%s seconds ago)\n", time2str( "%c", $epoch ), $diff;
    exit $exit_code;
}
elsif ( $exit_code == 2 ) {
    printf "[Critical] Message received over 15 minutes ago :: %s (%s seconds ago)\n", time2str( "%c", $epoch ), $diff;
    exit $exit_code;
}
else {
    printf "[?] No messages available\n";
    exit 2;
}
