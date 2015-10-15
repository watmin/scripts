#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : check-yum-updates.pl
#: Version : 1.0
#: Path    : /opt/sv/bin/check-yum-updates.pl
#: Params  : See --help
#: Desc    : Sends an email if yum updates are available

use strict;
use warnings;

use Getopt::Long;
use Sys::Hostname;

if (!@ARGV) { help(0) }

my %args = ();
GetOptions(
    'h|help'      => \$args{'help'},
    'e|email=s'   => \$args{'email'},
) or help(1);

if ( $args{'help'} )   { help(0) }
if ( !$args{'email'} ) { die "[!] Missing requirement --email\n" }

my $check = check_for_updates();

if ($check) {
    my $mailer = open_mailer();
    
    my $body = '';
    $body .= sprintf "Updates available on ${\hostname}.\n";
    $body .= sprintf "\n" . '=' x 72 . "\n\nOutput of `yum check-update`:\n\n";
    $body .= sprintf "%s\n", $check;

    print $mailer "To: $args{'email'}\n";
    print $mailer "From: root\@${\hostname}\n";
    print $mailer "Subject: [Updates] yum updates available on ${\hostname}\n";
    print $mailer "Content-type: text/plain\n";
    print $mailer "$body\n";

    close $mailer;

    exit;
}

exit;

sub help {
    my ($ec) = @_;

    print <<'EOH';
check-yum-updates.pl - Send an email if updates are available

Example: check-yum-updates.pl --email it@smartvault.com

Parameters:
  -e|--email     Email account to send update report to

Options:
  -h|--help      Shows this output;

EOH

    exit $ec;
}

sub check_for_updates {
    my $yum_out = `yum check-update`;

    if ( $? >> 8 == 100 ) {
        return $yum_out;
    }

    return;
}

sub open_mailer {
    open my $mailer, "|/usr/sbin/sendmail -t"
      or die "[!] Failed to open sendmail pipe: $!\n";

    return $mailer;
}

