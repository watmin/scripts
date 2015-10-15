#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : sv-clone.pl
#: Version : 1.2
#: Path    : /opt/sv/bin/sv-clone
#: Params  : --source-sr, --destination, --passwd-file, --guests
#: Desc    : Snapshots and clones machines to another server
#: Changes :
#: 1.1     : Checking for mounted CDs before starting
#: 1.2     : Removed unneccessary snapshot, added guest name to snapshot, cleaned up output

use strict;
use warnings;

use Getopt::Long;
use POSIX qw/:sys_wait_h/;

my $VERSION = '1.2';

@ARGV or help(0);

my %args;
GetOptions(
    'h|help'          => \$args{'help'},
    's|source-sr=s'   => \$args{'source-sr'},
    'd|destination=s' => \$args{'destination'},
    'f|passwd-file=s' => \$args{'passwd-file'},
    'g|guests=s'      => \$args{'guests'},
) or help(1);

$args{'help'} and help(0);

if (!$args{'source-sr'} or !$args{'destination'} or !$args{'passwd-file'} or !$args{'guests'}) {
    die "Was not provided all arguments. See $0 -h\n";
}

my @guests = split /,/, $args{'guests'};
my %map;
chomp(my $temp_file = `mktemp`);

print "Checking for mounted cds\n";
my $failed;
for my $guest (@guests) {
    my %vm = get_xe_hash("xe vm-list params=uuid name-label='$guest'");
    my %check = get_xe_hash("xe vm-cd-list vm=$vm{'uuid'}");
    if ( $check{'empty'} ne 'true' ) {
        $failed++;
        print "[!] The VM '$guest' has a CD mounted, eject it\n";
    }
}
die "VMs have CD mounted, eject them.\n" if $failed;

print "Performing prelimiary snapshots\n";
for my $guest (@guests) {
    print "Operating on '$guest'\n";
    $map{$guest}{'vm-uuid'}       = get_vm_uuid( $guest );
    $map{$guest}{'snapshot-uuid'} = create_vm_snapshot( $map{$guest}{'vm-uuid'}, $guest );
}

print "Performing export and migration\n";
for my $guest (@guests) {
    print "Operating on '$guest'\n";
    my $snapshot_file = export_vm_snapshot( $args{'source-sr'}, $map{$guest}{'snapshot-uuid'} );
    my $import_uuid = import_vm_export( $args{'destination'}, $args{'passwd-file'}, $snapshot_file );
    rename_vm( $args{'destination'}, $args{'passwd-file'}, $import_uuid, $guest );
    delete_export( $snapshot_file );
    delete_snapshot( $map{$guest}{'snapshot-uuid'} );
}

unlink $temp_file;

exit;

sub create_vm_snapshot {
    my ( $uuid, $guest ) = @_;

    my $epoch = time;
    print "Snapshoting '$uuid'...";
    chomp(my $snapshot_uuid = `xe vm-snapshot new-name-label="snapshot-temp.$guest.$epoch" uuid=$uuid`);
    die "Failed to snapshot '$uuid': $snapshot_uuid\n" if ($? > 0);
    print "Done. Snapshot is $snapshot_uuid\n";

    return $snapshot_uuid;
}

sub export_vm_snapshot {
    my ( $sr, $uuid ) = @_;

    my $epoch = time;
    my $export_path = "/var/run/sr-mount/$sr/$uuid.$epoch";
    my $template = `xe template-param-set is-a-template=false ha-always-run=false uuid=$uuid`;
    die "Failed to remove template settings on '$uuid': $template" if ($? > 0);
    print "Exporting '$uuid' to '$export_path'...\n";
    my $pid = fork;
    if (!$pid) {
        my $export = `xe vm-export vm=$uuid filename=$export_path`;
        die "Failed to export '$uuid': $export" if ($? > 0);
        exit;
    }
    else {
        $| = 1;
        print 'Completion:';
        sleep 3;
        while () {
            my $check = waitpid($pid, WNOHANG);
            if ($check == -1) {
                die "Failed to export.";
            }
            elsif (!$check) {
                my %hash = get_xe_hash("xe task-list params=progress name-label='Export of VM: $uuid'");
                printf "\rCompletion: %6.2f%%", ( 100 * $hash{'progress'} ); 
                sleep 3;
            }
            elsif ($check) {
                print "\rCompletion: 100.00%\n";
                last;
            }
        }
    }
    wait;

    return $export_path;
}

sub import_vm_export {
    my ( $host, $passwd_file, $path ) = @_;

    print "Importing '$path' to '$host'...\n";
    my $import_uuid;
    my $pid = fork;
    if (!$pid) {
        chomp($import_uuid = `xe -s $host -pwf $passwd_file vm-import filename=$path`);
        die "Failed to import '$path' to '$host': $import_uuid" if ($? > 0);

        open my $handle, '>', $temp_file;
        print $handle $import_uuid;
        close $handle;

        exit;
    }
    else {
        $| = 1;
        print 'Completion:';
        sleep 3;
        while () {
            my $check = waitpid($pid, WNOHANG);
            if ($check == -1) {
                die "Failed to import.";
            }
            elsif (!$check) {
                my %hash = get_xe_hash("xe -s $host -pwf $passwd_file task-list params=progress name-label='VM import'");
                printf "\rCompletion: %6.2f%%", ( 100 * $hash{'progress'} ); 
                sleep 3; 
            }   
            elsif ($check) {
                print "\rCompletion: 100.00%\n";
                last;
            }   
        }
    }   
    wait;

    open my $handle, '<', $temp_file;
    chomp(($import_uuid) = <$handle>);
    close $handle;

    return $import_uuid;
}

sub rename_vm {
    my ( $host, $passwd_file, $uuid, $name_label ) = @_;

    print "Renaming '$uuid' to '$name_label' on '$host'...";
    my $rename = `xe -s $host -pwf $passwd_file vm-param-set uuid=$uuid name-label=$name_label`;
    die "Failed to remain '$uuid' to '$name_label' on '$host': $rename" if ($? > 0);
    print "Done\n";

    return;
}

sub delete_export {
    my ($file) = @_;

    print "Deleting export '$file'...";
    unlink $file or die "Failed to delete '$file': $!";
    print "Done\n";

    return;
}

sub delete_snapshot {
    my ($uuid) = @_;

    print "Deleting snapshot '$uuid'...";
    my $uninstall = `xe snapshot-uninstall uuid=$uuid force=true`;
    die "Failed to delete snapshot '$uuid': $uninstall" if ($? > 0);
    print "Done\n";

    return;
}

sub get_vm_uuid {
    my ($name_label) = @_;

    print "Getting UUID of '$name_label'...";
    my %hash = get_xe_hash("xe vm-list params=uuid name-label=$name_label");
    my $uuid = $hash{'uuid'};
    print "Done. UUID is '$uuid'\n";

    return $uuid;
}

sub get_xe_hash {
    my ($command) = @_;

    my %hash;
    my @lines = `$command`;
    die "Failed to get result set from $command: @lines" if ($? > 0);
    for my $line (@lines) {
        $line =~ /^\s*(\S+)\s\(\s?\S{2,3}\)\s*:\s+(.*)/;
        next if !$1;
        $hash{$1} = $2;
    }

    return %hash;
}

sub help {
    my $exit_code = @_;

    print <<"EOH";
SmartVault XenServer Live Migration tool - Version $VERSION

Usage: $0 -s 'sr-uuid' -d 'ip.ad.dr.ess' -f 'dest-creds-file' -g guests,to,move

  -h|--help           Shows this output

Required Switches:
  -s|--source-sr      UUID of the source Storage Repository to hold the temp export
  -d|--destination    Target XenServer to clone to
  -f|--passwd-file    XenServer credential file for destination
  -g|--guests         Comma separated list of guests to clone

Notes:
  The passwd-file needs to contain two lines, user name on line 1 password on line 2
  You need to run this script from the source server

EOH

    exit $exit_code;
}

