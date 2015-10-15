#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : basenline.pl
#: Version : 2.4.3
#: Path    : /opt/sv/bin/baseline
#: Params  : See --help
#: Desc    : Manage snapshots for baselining preprodution
#: Changes :
#: 2.0     : Completely rewritten to use Xen API
#: 2.1     : Added sanity check for creating snapshots
#: 2.2     : Baselining now creates snapshots before exporting
#: 2.2.1   : Condensed output lines during baselining
#: 2.3.0   : Added cleanup routine
#: 2.3.1   : Added force to restore allowing nonexistent VMs to be restored
#: 2.3.2   : Added warns to API query failures
#: 2.4.0   : MAC addresses are now recorded at export and reused at import
#: 2.4.1   : Snapshotting now ignores snapshots created with -B, --baseline
#: 2.4.2   : Fixed bug with snapshot ignoring baseline generated snapshots
#: 2.4.3   : Now correctly destroy VM, including VDIs

use strict;
use warnings;

use Xen::API;
use Net::HTTP;
use HTTP::Status qw/:constants/;
use URI;
use Getopt::Long qw/:config no_ignore_case/;
use Sys::Hostname;
use POSIX qw/strftime/;
use Term::ProgressBar;

my $VERSION = '2.4.3';
my $AUTHOR  = 'John Shields';
my $EMAIL   = 'john.shields@smartvault.com';

$| = 1;

my $cred_file = '/root/.local_xen';

my $true  = RPC::XML::boolean->new(1);
my $false = RPC::XML::boolean->new(0);

if ( !@ARGV ) {
    help();
    exit;
}

my %args;
GetOptions(
    'h|help'           => \$args{'help'},
    'b|baseline'       => \$args{'baseline'},
    's|snapshot'       => \$args{'snapshot'},
    'r|revert'         => \$args{'revert'},
    'R|restore=s'      => \$args{'restore'},
    't|tag=s'          => \$args{'tag'},
    'S|list-snapshots' => \$args{'snapshots'},
    'B|list-baselines' => \$args{'baselines'},
    'C|cleanup'        => \$args{'cleanup'},
    'force'            => \$args{'force'},
) or die "See $0 -h\n";

if ( $args{'help'} ) {
    help();
    exit;
}

my @check_args = qw/baseline snapshot revert restore snapshots baselines cleanup/;
my $check;
for (@check_args) {
    $check++ if $args{$_};
}
die "Too many switches provided.\n" if $check > 1;

die "Credential file missing\n" if !-f $cred_file;
open my $cred_h, '<', $cred_file or die "Failed to open '$cred_file'\n";
chomp( my ( $username, $password, $hostname ) = <$cred_h> );
close $cred_h;

my $xen = Xen::API->new( $hostname, $username, $password );

if ( $args{'baseline'} ) {
    print "Starting baseline operations...\n";
    baseline( $xen, $args{'tag'} );
    print "Completed baseline operations\n";
    exit;
}

if ( $args{'snapshot'} ) {
    print "Starting snapshot operations...\n";
    snapshot( $xen, $args{'tag'} );
    print "Completed snapshot operations\n";
    exit;
}

if ( $args{'revert'} ) {
    print "Starting revert operations...\n";
    revert($xen);
    print "Completed revert operations\n";
    exit;
}

if ( $args{'restore'} ) {
    print "Starting restore operations...\n";
    restore( $xen, $args{'restore'}, $args{'force'} );
    print "Completed restore operations\n";
    exit;
}

if ( $args{'snapshots'} ) {
    print "Collecting snapshots...\n";
    snapshots($xen);
    exit;
}

if ( $args{'baselines'} ) {
    print "Collecting baselines...\n";
    baselines($xen);
    exit;
}

if ( $args{'cleanup'} ) {
    print "Cleanup starting...\n";
    cleanup( $xen, $args{'force'} );
    print "Completed cleanup\n";
    exit;
}

sub help {
    print <<EOH;
Usage: $0 ACTION [OPTION]
Manage Xen VM snapshot, export and import operations
Example: baseline -b -t SVIT-31337

Modification Actions:
  -b, --baseline        Baselines all taggeg VMs (exports to disk)
                         Requires -t, --tag
  -s, --snapshot        Snapshots all taggeg VMs
                         Requires -t, --tag
  -r, --revert          Reverts all tagged VMs to snapshot
  -R, --restore         Restores all tagged VMs to supplied date
                         Requires date string, obtained from -B or --baselines
                         --force can be used to restore VMs which are not tagged
  -C, --cleanup         Removes any snapshots on snapshot tagged hosts
                         --force can be used to remove snapshots without asking

Report Actions:
  -B, --list-baselines  Lists all known baselines with their tag                                                        
  -S, --list-snapshots  Lists all tagged VMs with snapshot count and tag

Miscellaneous Actions:
  -h, --help            Shows this output

Options:
  -t, --tag             Tags the operation with provided string
  --force               Forces action to be done

Notes:
  Tagged guests cannot be snapshot more than once

Version: $VERSION -- $AUTHOR <$EMAIL>
EOH
    return;
}

sub baseline {
    my ( $xen, $tag ) = @_;

    my $output_dir = prime_baseline_dir( $xen, $tag );
    my %vms = get_baseline_vms($xen);

    my %snapshots;

    print "Creating snapshots...\n";
    for my $vm ( keys %vms ) {
        my $name = $vms{$vm}{'name_label'};
        print "Snapshotting '$name'...";
        my $temp_name = sprintf "__%s.%s.temp", time, $name;
        my $snapshot = snapshot_vm( $xen, $vm, $temp_name );
        $snapshots{$vm} = [ $snapshot, $temp_name ];
        print "Done.\n";
    }
    print "Completed snapshots.\n";

    print "Starting exports...\n";
    for my $vm ( keys %vms ) {
        my $name = $vms{$vm}{'name_label'};
        print "Starting on '$name'...\n";

        print "Cloning snapshot...";
        my ( $snapshot, $temp_name ) = @{ $snapshots{$vm} };
        my $clone = clone_vm( $xen, $snapshot, $temp_name );
        print "Done.\n";

        print "Exporting '$name'...\n";
        export_vm_to_disk( $xen, $snapshot, $name, "$output_dir/$temp_name.xva" );

        print "Saving MAC addresses...";
        save_macs( $xen, $vm, "$output_dir/$temp_name.mac" );
        print "Done.\n";

        print "Destroying temporary clone...";
        destroy_vm( $xen, $clone );
        print "Done.\n";

        print "Destroying temporary snapshot...";
        destroy_vm( $xen, $snapshot );
        print "Done.\n";

        print "Finished with '$name'\n";
    }
    print "Completed exports\n";

    return;
}

sub snapshot {
    my ( $xen, $tag ) = @_;

    die "No tag provided.\n" if !$tag;

    my %vms = get_snapshot_vms($xen);

    my %sanity_check;
    for my $vm ( keys %vms ) {
        my $name  = $vms{$vm}{'name_label'};
        my $count = strip_baselined_snapshots( $xen, @{ $vms{$vm}{'snapshots'} } );
        my $tag   = $vms{$vm}{'other_config'}{'XenCenter.CustomFields.snapshot-tag'} || 'null';

        if ( $count > 0 ) {
            $sanity_check{$name} = [ $count, $tag ];
        }
    }

    if ( keys %sanity_check > 0 ) {
        print "Snapshots found on the following hosts, cannot continue:\n";

        for my $name ( keys %sanity_check ) {
            printf "[%s] Snapshots: %s ; Tag: %s\n", $name, @{ $sanity_check{$name} };
        }

        exit 1;
    }

    for my $vm ( keys %vms ) {
        my $name = $vms{$vm}{'name_label'};
        print "Starting on '$name'...\n";

        my $snapshot_name = "$name - $tag";

        print "Creating snapshot...";
        my $snapshot = snapshot_vm( $xen, $vm, $snapshot_name );
        print "Done.\n";

        print "Tagging vm...";
        vm_set_other_config( $xen, $vm, { 'XenCenter.CustomFields.snapshot-tag' => "$tag" } );
        print "Done.\n";

        print "Finished with '$name'\n";
    }

    return;
}

sub revert {
    my ($xen) = @_;

    my %vms = get_snapshot_vms($xen);

    for my $vm ( keys %vms ) {
        my $name = $vms{$vm}{'name_label'};
        print "Starting on '$name'...\n";

        if ( scalar @{ $vms{$vm}{'snapshots'} } > 1 ) {
            die "More than one snapshot found on $name, cannot continue.\n";
        }
        elsif ( scalar @{ $vms{$vm}{'snapshots'} } != 1 ) {
            die "Cannot find snapshot to rever to, cannot continue.\n\n";
        }

        my ($snapshot) = @{ $vms{$vm}{'snapshots'} };

        print "Reverting to snapshot...";
        revert_vm_to_snapshot( $xen, $snapshot );
        print "Done.\n";

        print "Removing snapshot tag...";
        vm_set_other_config( $xen, $vm, { 'XenCenter.CustomFields.snapshot-tag' => '' } );
        print "Done.\n";

        print "Destroying snapshot...";
        destroy_vm( $xen, $snapshot );
        print "Done.\n";

        print "Starting vm...";
        start_vm( $xen, $vm );
        print "Done.\n";

        print "Finished with '$name'\n";
    }

    return;
}

sub restore {
    my ( $xen, $date, $force ) = @_;

    my $baseline_dir = get_baseline_dir($xen);
    my $restore_dir  = "$baseline_dir/$date";

    if ( !-d $restore_dir ) {
        die "Baseline directory '$restore_dir' not found\n";
    }

    opendir( my $dir_h, $restore_dir ) or die "Failed to open directory '$restore_dir': $!\n";
    my @xvas = grep { /.*\.xva$/ } readdir($dir_h);
    closedir $dir_h;

    my %vms = get_baseline_vms($xen);

    for my $xva (@xvas) {
        ( my $temp_name = $xva ) =~ s/^(.*)\.xva$/$1/;
        ( my $vm_name   = $xva ) =~ s/^__\d+\.(.*)\.temp\.xva$/$1/;
        ( my $mac_addrs = $xva ) =~ s/\.xva$/.mac/;

        my ( $check, %check_record ) = get_vm_from_name_label( $xen, $vm_name );
        if ( !$check ) {
            warn "The XVA file '$restore_dir/$xva' had no matching vm\n";
            next if !$force;
        }

        my $vm = $check || $vm_name;

        print "Starting on '$vm_name'...\n";

        print "Restoring $vm_name from disk...\n";
        import_vm_from_disk( $xen, $vm, "$restore_dir/$xva" );

        my ( $restored, %restored_record ) = get_vm_from_name_label( $xen, $temp_name );

        print "Provisioning restored vm...";
        provision_vm( $xen, $restored );
        print "Done.\n";

        print "Stopping vm...";
        stop_vm( $xen, $vm );
        print "Done.\n";

        print "Destroying current vm...";
        destroy_vm( $xen, $vm );
        print "Done.\n";

        print "Renaming restored vm...";
        rename_vm( $xen, $restored, $vm_name );
        print "Done.\n";

        print "Correcting MAC addresses on vm...";
        update_macs( $xen, $restored, "$restore_dir/$mac_addrs" );
        print "Done.\n";

        print "Starting $vm_name...";
        start_vm( $xen, $restored );
        print "Done.\n";
    }

    return;
}

sub snapshots {
    my ($xen) = @_;

    my %vms = get_snapshot_vms($xen);

    for my $vm ( keys %vms ) {
        my $name  = $vms{$vm}{'name_label'};
        my $count = strip_baselined_snapshots( $xen, @{ $vms{$vm}{'snapshots'} } );
        my $tag   = $vms{$vm}{'other_config'}{'XenCenter.CustomFields.snapshot-tag'} || 'null';
        print "[$name] Snapshots: $count ; Tag: $tag\n";
    }

    return;
}

sub baselines {
    my ($xen) = @_;

    my $baseline_dir = get_baseline_dir($xen);

    if ( !-d $baseline_dir ) {
        die "Baseline directory '$baseline_dir' not found\n";
    }

    opendir( my $dir_h, $baseline_dir ) or die "Failed to open directory '$baseline_dir': $!\n";
    my @dirs = grep { !/^.{1,2}$/ } readdir($dir_h);
    close $dir_h;

    for my $dir ( sort @dirs ) {
        next if !-d $dir;
        open my $tag_h, '<', "$baseline_dir/$dir/.tag" or die "Failed to open '$baseline_dir/$dir/.tag': $!\n";
        chomp( my $tag = <$tag_h> );
        close $tag_h;

        print "[$tag] $dir\n";
    }

    return;
}

sub get_baseline_vms {
    my ($xen) = @_;

    my %baseline_vms;
    my %vm_records = get_vms($xen);
    for my $vm ( keys %vm_records ) {
        my $baseline = $vm_records{$vm}{'other_config'}{'XenCenter.CustomFields.baseline'};
        if ( $baseline and $baseline == 1 ) {
            next if $vm_records{$vm}{'is_a_snapshot'};
            next if $vm_records{$vm}{'is_a_template'};
            $baseline_vms{$vm} = $vm_records{$vm};
        }
    }

    return %baseline_vms;
}

sub get_snapshot_vms {
    my ($xen) = @_;

    my %snapshot_vms;
    my %vm_records = get_vms($xen);
    for my $vm ( keys %vm_records ) {
        my $snapshot = $vm_records{$vm}{'other_config'}{'XenCenter.CustomFields.snapshot'};
        if ( $snapshot and $snapshot == 1 ) {
            next if $vm_records{$vm}{'is_a_snapshot'};
            next if $vm_records{$vm}{'is_a_template'};
            $snapshot_vms{$vm} = $vm_records{$vm};
        }
    }

    return %snapshot_vms;
}

sub get_baseline_dir {
    my ($xen) = @_;

    my ( $host, %host_record ) = get_this_host($xen);
    my $baseline_dir = $host_record{'other_config'}{'XenCenter.CustomFields.baseline-dir'};

    return $baseline_dir;
}

sub prime_baseline_dir {
    my ( $xen, $tag ) = @_;

    die "No tag provided.\n" if !$tag;
    my $timestamp = strftime "%Y-%m-%d_%H:%M:%S", localtime;

    my $baseline_dir = get_baseline_dir($xen);
    my $output_dir   = "$baseline_dir/$timestamp";

    if ( !-d $baseline_dir ) {
        mkdir $baseline_dir or die "Failed to create directory '$baseline_dir': $!\n";
    }

    if ( -d "$output_dir" ) {
        die "Baseline directory '$output_dir' already exists.\n";
    }
    elsif ( !-d "$output_dir" ) {
        mkdir "$output_dir" or die "Failed to create directory '$output_dir': $!\n";
    }

    open my $tag_h, '>', "$output_dir/.tag"
      or die "Failed to open tag file '$output_dir/.tag': $!\n";
    print $tag_h "$tag\n";
    close $tag_h;

    return $output_dir;
}

sub get_host_record {
    my ( $xen, $host ) = @_;

    my %host_record;
    eval { %host_record = %{ Xen::API::host::get_record( $xen, $host ) }; };

    warn "Found no host record\n" if !%host_record;

    return %host_record;
}

sub get_vm_record {
    my ( $xen, $vm ) = @_;

    my %vm_record;
    eval { %vm_record = %{ Xen::API::VM::get_record( $xen, $vm ) }; };

    warn "Found no VM record\n" if !%vm_record;

    return %vm_record;
}

sub get_task_record {
    my ( $xen, $task ) = @_;

    my %task_record;
    eval { %task_record = %{ Xen::API::task::get_record( $xen, $task ) }; };

    warn "Found no task record\n" if !%task_record;

    return %task_record;
}

sub get_vif_record {
    my ( $xen, $vif ) = @_;

    my %vif_record;
    eval { %vif_record = %{ Xen::API::VIF::get_record( $xen, $vif ) }; };

    warn "Found no VIF record\n" if !%vif_record;

    return %vif_record;
}

sub get_vbd_record {
    my ( $xen, $vbd ) = @_;

    my %vbd_record;
    %vbd_record = %{ Xen::API::VBD::get_record( $xen, $vbd ) };
    eval { %vbd_record = %{ Xen::API::VBD::get_record( $xen, $vbd ) }; };

    warn "Found no VBD record\n" if !%vbd_record;

    return %vbd_record;
}

sub get_vms {
    my ($xen) = @_;

    my %vm_records;
    eval { %vm_records = %{ Xen::API::VM::get_all_records($xen) }; };

    warn "Found no VM records\n" if !%vm_records;

    return %vm_records;
}

sub get_hosts {
    my ($xen) = @_;

    my %host_records;
    eval { %host_records = %{ Xen::API::host::get_all_records($xen) }; };

    warn "Found no host records\n" if !%host_records;

    return %host_records;
}

sub get_tasks {
    my ($xen) = @_;

    my %task_records;
    eval { %task_records = %{ Xen::API::task::get_all_records($xen) }; };

    warn "Found no task records\n" if !%task_records;

    return %task_records;
}

sub get_vifs {
    my ($xen) = @_;

    my %vif_records;
    eval { %vif_records = %{ Xen::API::VIF::get_all_records($xen) }; };

    warn "Found no VIF records\n" if !%vif_records;

    return %vif_records;
}

sub get_vbds {
    my ($xen) = @_;

    my %vbd_records;
    eval { %vbd_records = %{ Xen::API::VBD::get_all_records($xen) }; };

    warn "Found no VBD records\n" if !%vbd_records;
    return %vbd_records;
}

sub get_this_host {
    my ($xen) = @_;

    my ( $host, %this_host );
    my %hosts = get_hosts($xen);
    for my $record ( keys %hosts ) {
        if ( $hosts{$record}{'hostname'} eq hostname ) {
            $host      = $record;
            %this_host = %{ $hosts{$host} };
        }
    }

    return ( $host, %this_host );
}

sub get_vm_vifs {
    my ( $xen, $vm ) = @_;

    my @vm_vifs;

    my %vifs = get_vifs($xen);

    for my $vif ( keys %vifs ) {
        push @vm_vifs, $vif if $vifs{$vif}{'VM'} eq $vm;
    }

    return @vm_vifs;
}

sub get_vm_vbds {
    my ( $xen, $vm ) = @_;

    my @vm_vbds;

    my %vbds = get_vbds($xen);

    for my $vbd ( keys %vbds ) {
        push @vm_vbds, $vbd if $vbds{$vbd}{'VM'} eq $vm;
    }

    return @vm_vbds;
}

sub start_task {
    my ( $xen, $name, $description ) = @_;

    my $task = Xen::API::task::create( $xen, $name, $description );

    return $task;
}

sub finish_task {
    my ( $xen, $task ) = @_;

    Xen::API::task::destroy( $xen, $task );

    return;
}

sub export_vm {
    my ( $xen, $vm, $name ) = @_;

    my %vm_record = get_vm_record( $xen, $vm );
    if ( $vm_record{'power_state'} ne 'Halted' ) {
        die "Cannot export VM that is not halted.\n";
    }

    my $export_task = start_task( $xen, "export_$name", "Export VM $name" );

    my $export_uri = URI->new( $xen->{'uri'} );
    $export_uri->path('export');
    $export_uri->query_param( 'session_id' => $xen->{'session'} );
    $export_uri->query_param( 'task_id'    => $export_task );
    $export_uri->query_param( 'ref'        => $vm );

    my $export = Net::HTTP->new( 'Host' => $export_uri->host_port )
      or die "Failed to create Net::HTTP object: $@\n";

    $export->write_request(
        'GET'        => $export_uri->path_query,
        'User-Agent' => 'SmartVault-Baseline',
    );

    my ( $code, $message, %headers ) = $export->read_response_headers;
    die "Export response was not OK: $code, $message\n" if $code != HTTP_OK;

    return $export_task, $export;
}

sub import_vm {
    my ( $xen, $vm ) = @_;

    my %vm_record = get_vm_record( $xen, $vm );
    my $name = $vm_record{'name_label'} || $vm;

    my $import_task = start_task( $xen, "import_$name", "Import VM $name" );

    my $import_uri = URI->new( $xen->{'uri'} );
    $import_uri->path('import');
    $import_uri->query_param( 'session_id' => $xen->{'session'} );
    $import_uri->query_param( 'task_id'    => $import_task );

    my $import = Net::HTTP->new( 'Host' => $import_uri->host_port )
      or die "Failed to create Net::HTTP object: $@\n";

    $import->write_request(
        'PUT'        => $import_uri->path_query,
        'User-Agent' => 'SmartVault-Baseline',
    );

    return $import_task, $import;
}

sub export_vm_to_disk {
    my ( $xen, $vm, $name, $xva ) = @_;

    my ( $export_task, $export ) = export_vm( $xen, $vm, $name );

    my $pid = fork;
    if ( !$pid ) {
        open my $export_h, '>', "$xva"
          or die "Failed to open '$xva': $!\n";
        print $export_h $_ while <$export>;
        close $export_h;

        exit;
    }
    else {
        check_progress( $xen, $export_task );
    }

    finish_task( $xen, $export_task );

    return;
}

sub import_vm_from_disk {
    my ( $xen, $vm, $xva ) = @_;

    die "Cannot find '$xva'\n" if !-f $xva;

    open my $xva_h, '<', $xva or die "Failed to open '$xva': $!\n";

    my ( $import_task, $import ) = import_vm( $xen, $vm );

    my $pid = fork;
    if ( !$pid ) {
        print $import "$_" while <$xva_h>;
        close $xva_h;

        exit;
    }
    else {
        check_progress( $xen, $import_task );
    }

    my ( $code, $message, %headers ) = $import->read_response_headers;
    die "Import response was not OK: $code, $message\n" if $code != HTTP_OK;

    finish_task( $xen, $import_task );

    return;
}

sub check_progress {
    my ( $xen, $task ) = @_;

    my $progress = Term::ProgressBar->new( { 'count' => 1000, 'ETA' => 'linear' } );
    while () {
        my %check_task = get_task_record( $xen, $task );
        if ( $check_task{'status'} eq 'success' ) {
            $progress->update(1000);
            last;
        }
        elsif ( $check_task{'status'} eq 'pending' ) {
            my $percentage = 1000 * $check_task{'progress'};
            $progress->update($percentage);
        }
        else {
            warn "Task status is not success or pending: '$check_task{'status'}'!\n";
            last;
        }
        sleep 2;
    }

    return;
}

sub snapshot_vm {
    my ( $xen, $vm, $name ) = @_;

    my $snapshot = Xen::API::VM::snapshot( $xen, $vm, $name );

    return $snapshot;
}

sub clone_vm {
    my ( $xen, $vm, $name ) = @_;

    my $clone = Xen::API::VM::clone( $xen, $vm, $name );

    return $clone;
}

sub destroy_vm {
    my ( $xen, $vm ) = @_;

    my %vm_record = get_vm_record( $xen, $vm );

    if ( !%vm_record ) {
        warn "No VM record found, cannot destroy VM\n";
        return;
    }

    destroy_vm_vdis( $xen, $vm );

    Xen::API::VM::destroy( $xen, $vm );

    return;
}

sub destroy_vm_vdis {
    my ( $xen, $vm ) = @_;

    my @vbds = get_vm_vbds( $xen, $vm );

    for my $vbd (@vbds) {
        my %vbd_record = get_vbd_record( $xen, $vbd );
        next if $vbd_record{'VDI'} eq 'OpaqueRef:NULL';
        my $vdi = $vbd_record{'VDI'};
        Xen::API::VDI::destroy( $xen, $vdi );
    }

    return;
}

sub vm_set_other_config {
    my ( $xen, $vm, $update ) = @_;

    my %vm_record      = get_vm_record( $xen, $vm );
    my %current_config = %{ $vm_record{'other_config'} };
    my %new_config     = ( %current_config, %{$update} );

    Xen::API::VM::set_other_config( $xen, $vm, \%new_config );

    return;
}

sub revert_vm_to_snapshot {
    my ( $xen, $snapshot ) = @_;

    Xen::API::VM::revert( $xen, $snapshot );

    return;
}

sub start_vm {
    my ( $xen, $vm ) = @_;

    my %vm_record = get_vm_record( $xen, $vm );

    if ( $vm_record{'power_state'} ne 'Halted' ) {
        die "Cannot start VM that is not Halted\n";
    }

    Xen::API::VM::start( $xen, $vm, $false, $true );

    return;
}

sub stop_vm {
    my ( $xen, $vm ) = @_;

    my %vm_record = get_vm_record( $xen, $vm );

    if ( !%vm_record ) {
        warn "No VM record found, cannot stop VM\n";
        return;
    }

    if ( $vm_record{'power_state'} ne 'Running' ) {
        die "Cannot stop VM that is not Running\n";
    }

    Xen::API::VM::shutdown( $xen, $vm );

    return;
}

sub get_vm_from_name_label {
    my ( $xen, $name_label ) = @_;

    my %vms = get_vms($xen);

    my ( $vm, %vm_record );
    for my $record ( keys %vms ) {
        if ( $vms{$record}{'name_label'} eq $name_label ) {
            $vm        = $record;
            %vm_record = %{ $vms{$record} };
        }
    }

    return ( $vm, %vm_record );
}

sub provision_vm {
    my ( $xen, $vm ) = @_;

    Xen::API::VM::provision( $xen, $vm );

    return;
}

sub rename_vm {
    my ( $xen, $vm, $name ) = @_;

    Xen::API::VM::set_name_label( $xen, $vm, $name );

    return;
}

sub have_snapshots {
    my ($xen) = @_;

    my %vms = get_snapshot_vms($xen);

    my %snapshots;
    for my $vm ( keys %vms ) {
        my $count = strip_baselined_snapshots( $xen, @{ $vms{$vm}{'snapshots'} } );
        if ( $count > 0 ) {
            for my $snapshot ( @{ $vms{$vm}{'snapshots'} } ) {
                next if is_baselining( $xen, $snapshot );
                my %vm_record = get_vm_record( $xen, $snapshot );
                $snapshots{$snapshot} = \%vm_record;
            }
        }
    }

    return %snapshots;
}

sub print_snapshots {
    my (%snapshots) = @_;

    for my $snapshot ( keys %snapshots ) {
        my %parent      = get_vm_record( $xen, $snapshots{$snapshot}{'snapshot_of'} );
        my $parent_name = $parent{'name_label'};
        my $name        = $snapshots{$snapshot}{'name_label'};
        my $tag         = $snapshots{$snapshot}{'other_config'}{'XenCenter.CustomFields.snapshot-tag'} || 'null';
        print "VM: $parent_name ; Snapshot: $name ; Tag: $tag\n";
    }

    return;
}

sub cleanup {
    my ( $xen, $force ) = @_;

    print "Looking for snapshots...\n";
    my %snapshots = have_snapshots($xen);
    if (%snapshots) {
        print "Found the following snapshots:\n";
        print_snapshots(%snapshots);
        process_cleanup( $xen, \%snapshots, $force );
    }
    else {
        print "No snapshots found\n";
    }

    return;
}

sub process_cleanup {
    my ( $xen, $snapshots, $force ) = @_;

    for my $snapshot ( keys %{$snapshots} ) {
        my $snapshot_of = $snapshots->{$snapshot}{'snapshot_of'};
        my %parent      = get_vm_record( $xen, $snapshot_of );
        my $parent_name = $parent{'name_label'};
        my $name        = $snapshots->{$snapshot}{'name_label'};
        my $tag         = $snapshots->{$snapshot}{'other_config'}{'XenCenter.CustomFields.snapshot-tag'} || 'null';

        if ($force) {
            print "Destroying '$parent_name', snapshot: '$name', tag '$tag'...";
            destroy_vm( $xen, $snapshot );
            print "Done.\n";
        }
        else {
            print "Destroy '$parent_name', snapshot: '$name', tag: '$tag'? (y/n): ";
            chomp( my $answer = <> );
            if ( $answer =~ m/^(y|yes)$/i ) {
                print "Destroying '$parent_name', snapshot: '$name', tag '$tag'...";
                destroy_vm( $xen, $snapshot );
                print "Done.\n";
            }
        }
    }

    return;
}

sub save_macs {
    my ( $xen, $vm, $addr_file ) = @_;

    my @vm_vifs = get_vm_vifs( $xen, $vm );
    my %macs;

    open my $addr_file_h, '>', $addr_file
      or die "Failed to open MAC address file '$addr_file': $!\n";
    for my $vif (@vm_vifs) {
        my %vif_record = get_vif_record( $xen, $vif );
        printf $addr_file_h "%s %s\n", $vif_record{'device'}, $vif_record{'MAC'};
    }
    close $addr_file_h;

    return;
}

sub update_macs {
    my ( $xen, $vm, $addr_file ) = @_;

    if ( !-f $addr_file ) {
        warn "No MAC file found, not modifiying MAC address\n";
        return;
    }

    my @vm_vifs = get_vm_vifs( $xen, $vm );
    my %macs;

    open my $addr_file_h, '<', $addr_file
      or die "Failed to open MAC address file '$addr_file': $!\n";
    my $line;
    while ( $line = <$addr_file_h> ) {
        chomp $line;
        $line =~ /(\d+)\s(\S+)/;
        my ( $device, $mac ) = ( $1, $2 );
        $macs{$device} = $mac;
    }
    close $addr_file_h;

    for my $vif (@vm_vifs) {
        my %new_vif = get_vif_record( $xen, $vif );
        $new_vif{'MAC'} = $macs{ $new_vif{'device'} };
        Xen::API::VIF::destroy( $xen, $vif );
        Xen::API::VIF::create( $xen, \%new_vif );
    }

    return;
}

sub strip_baselined_snapshots {
    my ( $xen, @snapshots ) = @_;

    my $count = 0;

    for my $snapshot (@snapshots) {
        $count++ if not is_baselining( $xen, $snapshot );
    }

    return scalar $count;
}

sub is_baselining {
    my ( $xen, $snapshot ) = @_;

    my %record = get_vm_record( $xen, $snapshot );

    my $check = 0;

    $check++ if $record{'name_label'} =~ /^__\d{10}.*?.temp$/;

    return $check;
}

