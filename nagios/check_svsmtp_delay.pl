#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_svsmtp_delay.pl
#: Version : 1.0
#: Path    : /usr/local/nagios/plugins/check_svsmtp_delay
#: Params  : None
#: Desc    : Checks to see what the SMTP delay is

use strict;
use warnings;

use Mail::POP3Client;
use Email::Simple;
use Date::Format;
use Date::Parse;

# Script variables
my $indicator = 'some_moderately_unique_string';
my $exit_code = 255;
my $warn = 60;
my $crit = 120;
my $diff = 0;
my $prefix = '?';

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
    my @rec = $email->header('Received');
    if ( $subject[0] =~ /^\Q${indicator}\E/ ) {
        unless ( $skip_flag == 1 ) {
            # Skip older messages that could be in the inbox
            $skip_flag = 1;

            # Get the received time
            chomp( my $rec_time = $rec[0] );
            $rec_time =~ /(?<=; )(.*?)(?=$)/;
            $rec_time = $1;
            $rec_time = str2time($rec_time);

            # Get the send time
            chomp( my $send_time = $rec[$#rec] );
            $send_time =~ /(?<=; )(.*?)(?=$)/;
            $send_time = $1;
            $send_time = str2time($send_time);

            # Get delivery time
            $diff = $rec_time - $send_time;

            # Set the Nagios exit code
            if ( $diff > $crit ) {
                $prefix = 'Critical';
                $exit_code = 2;
            }
            elsif ( $diff > $warn ) {
               $prefix = 'Warning';
               $exit_code = 1; 
            }
            elsif ( $diff < $warn ) {
                $prefix = 'OK';
                $exit_code = 0;
            }
        }
    }
    $pop->Delete($inbox_handle);
}
$pop->Close;

# Nagios output
if ( $exit_code =~ /^[012]$/ ) {
    printf "[%s] SmartVault SMTP Delay is %d seconds | delay=%is\n", $prefix, $diff, $diff;
    exit $exit_code;
}
else {
    printf "[%s] No messages available\n | delay=-1s", $prefix;
    exit 2;
}
