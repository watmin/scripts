#!/usr/bin/perl
# nagios: -epn
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : sv-nagios-email.pl
#: Version : 1.1.1
#: Path    : /usr/local/nagios/plugins/sv-nagios-email.pl
#: Params  : See --help
#: Desc    : Sends out formatted Nagios host alert emails
#:         :
#: Changes : 1.1
#:         : Added long host and service descriptions
#:         : 1.1.1
#:         : Changed Info: output line

use strict;
use warnings;

use Getopt::Long;
use URI::Escape;

# Nagios macros
my (
    $notification_type, $long_date_time, $contact_email,
    $host_name, $host_address, $host_state, $host_desc,
    $host_output, $long_host_output, $host_ack_comment,
    $service_state, $service_desc, $service_output,
    $long_service_output, $service_ack_comment
) = (0);

my $ack_link = 'https://office.smartvault.com:31337/cgi-bin/acknowledge.cgi';

# Help if no args
if (!@ARGV) {
    help(0)
}

# Handle arguments
my %args;
GetOptions(
    'h|help'                => \$args{help},
    't|type=s'              => \$args{type},
    'notification_type=s'   => \$notification_type,
    'long_date_time=s'      => \$long_date_time,
    'contact_email=s'       => \$contact_email,
    'host_name=s'           => \$host_name,
    'host_address=s'        => \$host_address,
    'host_state=s'          => \$host_state,
    'host_desc=s'           => \$host_desc,
    'host_output=s'         => \$host_output,
    'long_host_output=s'    => \$long_host_output,
    'host_ack_comment=s'    => \$host_ack_comment,
    'service_state=s'       => \$service_state,
    'service_desc=s'        => \$service_desc,
    'service_output=s'      => \$service_output,
    'long_service_output=s' => \$long_service_output,
    'service_ack_comment=s' => \$service_ack_comment
) or help(1);

# Help me
if ($args{help}) {
    help(0)
}

&validate;

if ($args{type} =~ /^host$/ ) {
    &host_notification;
}
elsif ($args{type} =~ /^service$/ ) {
    &service_notification;
}
else {
    die "[!] Invalid type of email, see --help\n";
}

sub help {
    my ( $ec ) = @_;

    printf <<'EOH';
sv-host-email.pl -- SmartVault Nagios mailer

Usage: sv-host-email.pl --parameter <arg> ... --parameter <arg>

Options:
  -h|--help              Displays this message

Required Parameters
  -t|--type              Either 'host' or 'service'
  --notification_type    Nagios macro '$NOTIFICATIONTYPE$'
  --long_date_time       Nagios macro '$LONGDATETIME$'
  --contact_email        Nagios macro '$CONTACTEMAIL$'
  --host_name            Nagios macro '$HOSTNAME$'
  --host_address         Nagios macro '$HOSTADDRESS$'

Host specific:

Required Host Parameters
  --host_state required  Nagios macro '$HOSTSTATE$'
  --host_output          Nagios macro '$HOSTOUTPUT$'
  --host_ack_comment     Nagios macro '$HOSTACKCOMMENT$'

Optional Host Parameters
  --long_host_output     Nagios macro '$LONGHOSTOUTPUT$'

Service specific:

Required Service Parameters
  --service_state        Nagios macro '$SERVICESTATE$'
  --service_desc         Nagios macro '$SERVICEDESC$'
  --service_output       Nagios macro '$SERVICEOUTPUT$'
  --service_ack_comment  Nagios macro '$SERVICEACKCOMMENT$'

Optional Service Parameters
  --long_service_output  Nagios macro '$LONGSERVICEOUTPUT$'

EOH

    exit $ec;
}

# Ensure all macros are supplied
sub validate {

    # Required macros for all emails
    if (!$notification_type) { die "[!] --notification_type required\n" }
    if (!$long_date_time)    { die "[!] --long_date_time required\n" }
    if (!$contact_email)     { die "[!] --contact_email required\n" }
    if (!$host_name)         { die "[!] --host_name required\n" } 
    if (!$host_address)      { die "[!] --host_address required\n" }

    # Required macros for host emails
    if ( $args{type} =~ /^host$/ ) {
        if (!$host_state)    { die "[!] --host_state required\n" }
        #if (!$host_desc)     { die "[!] --host_desc required\n" } # NYI
        if (!$host_output)   { die "[!] --host_output required\n" }
        if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
            if (!$host_ack_comment) { die "[!] --host_ack_comment required\n" }
            }
        }

    # Required marcros for service emails
    if ( $args{type} =~ /^service$/ ) {
        if (!$service_state)    { die "[!] --service_state required\n" }
        if (!$service_desc)     { die "[!] --service_desc required\n" }
        if (!$service_output)   { die "[!] --service_output required\n" }
        if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
            if (!$service_ack_comment) { die "[!] --service_ack_comment required\n" }
        }
    }

}

sub host_notification {

    my $subject = '';
    if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
        $subject .= sprintf "[%s] %s - %s\n", $host_state, $host_name, $notification_type;
    }
    else {
        $subject .= sprintf "[%s] %s\n", $host_state, $host_name;
    }

    my $body = '';
    $body .= "Nagios Host Nofication\n";
    $body .= "\n";
    $body .= sprintf "Notification Type: %s\n", $notification_type;
    $body .= sprintf "Host: %s\n", $host_name;
    $body .= sprintf "State: %s\n", $host_state;
    $body .= sprintf "Address: %s\n", $host_address;
    $body .= sprintf "Date/Time: %s\n", $long_date_time;
    $body .= "\n";
    $body .= "Info:\n";
    $body .= sprintf "%s\n", $host_output;
    $body .= "\n";

    if ($long_host_output) {
        $body .= "Additional Info:\n";
        $body .= "\n";
        $body .= sprintf "%s\n", $long_host_output;
        $body .= "\n";
    }

    if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
        $body .= "Acknowledgement:\n";
        $body .= "\n";
        $body .= sprintf "%s\n", $host_ack_comment;
        $body .= "\n";
    }
    elsif ($notification_type =~ /^PROBLEM$/) {
        $body .= "Acknowledgement link:\n";
        $body .= sprintf "%s?type=%s&host=%s\n", $ack_link, $args{type}, uri_escape($host_name);
        $body .= "\n";
    }

    mail( $subject, $body );

}

sub service_notification {

    my $subject = '';
    if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
        $subject .= sprintf "[%s] %s - %s :: %s\n", $service_state, $host_name,
            $notification_type, $service_desc;
    }
    else {
        $subject .= sprintf "[%s] %s :: %s\n", $service_state, $host_name, $service_desc;
    }

    my $body = '';
    $body .= "Nagios Service Nofication\n";
    $body .= "\n";
    $body .= sprintf "Notification Type: %s\n", $notification_type;
    $body .= sprintf "Host: %s\n", $host_name;
    $body .= sprintf "Service: %s\n", $service_desc;
    $body .= sprintf "State: %s\n", $service_state;
    $body .= sprintf "Address: %s\n", $host_address;
    $body .= sprintf "Date/Time: %s\n", $long_date_time;
    $body .= "\n";
    $body .= "Info:\n";
    $body .= sprintf "%s\n", $service_output;
    $body .= "\n";

    if ($long_service_output) {
        $body .= "Additional Info:\n";
        $body .= "\n";
        $body .= sprintf "%s\n", $long_service_output;
        $body .= "\n";
    }

    if ( $notification_type =~ /^ACKNOWLEDGEMENT$/ ) {
        $body .= "Acknowledgement:\n";
        $body .= "\n";
        $body .= sprintf "%s\n", $service_ack_comment;
        $body .= "\n";
    }
    elsif ($notification_type =~ /^PROBLEM$/) {
        $body .= "Acknowledgement link:\n";
        $body .= sprintf "%s?type=%s&host=%s&service=%s\n", $ack_link, $args{type},
          uri_escape($host_name), uri_escape($service_desc);
        $body .= "\n";
    }

    mail( $subject, $body );

}

sub mail {
    my ( $subject, $body ) = @_;

    `/usr/bin/printf "%b" "$body" | /usr/bin/mail -s "$subject" "$contact_email"`;

    if ($?) {
        die "[!] Failed to send message\n";
    }
    else {
        exit 0;
    }

}

exit 255;

