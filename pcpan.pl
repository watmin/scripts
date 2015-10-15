#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : Private CPAN
#: Version : 1.2
#: Path    : /usr/local/bin/pcpan
#: Params  : [ <CPAN::Module> <CPAN::Module> .. <CPAN::Module> ]
#: Desc    : Downloads CPAN modules and uploads to private repository
#: Changes : 1.1
#:         : Added support for .zip archives
#:         : 1.2
#:         : Suppressed warnings from poor author uploads

#/home/minicpan/.mcpani/config
#local: /home/minicpan/live
#remote: ftp://localhost
#repository: /home/minicpan/staging
#offline: yes
#passive: yes
#dirmode: 0755

use strict;
use warnings;
use Archive::Extract;
use CPAN::Mini;
use CPAN::Mini::Inject;
use CPAN::Mini::Webserver;
use CPAN::FindDependencies;

# Script variables
my $mini_home='/home/minicpan';
my $mini_conf="$mini_home/.mcpani/config";
my $mini_stag="$mini_home/staging";
my $stag_auth="$mini_stag/authors";
my $stag_mods="$mini_stag/modules";
my $stag_priv="$stag_auth/id/S/SV/SVPRIV";
my $mini_live="$mini_home/live";
my $live_auth="$mini_live/authors";
my $live_mods="$mini_live/modules";
my $live_priv="$live_auth/id/S/SV/SVPRIV";
my $temp_dir="$mini_home/tmp";
my @dirs = ( $mini_stag, $mini_live, $stag_auth, $stag_mods, $live_auth, $live_mods, $temp_dir );
my $priv_server='redacted';
my $priv_user='redacted';
my $priv_key="$mini_home/.ssh/redacted";
my $priv_path='/re/dact/ed';
my $priv_auth='SVPRIV';

# Sanity checks
if ( ! -d $mini_home ) { die '[!] Home does not exist' }
if ( ! -f $mini_conf ) { die '[!] Configuration does not exist' }

# Create our directory structure
for (@dirs) { if ( ! -d ) { mkdir $_ or die "[!] Failed to create directory: $_" } }

# Create required files
if ( ! -f "$live_auth/01mailrc.txt.gz" ) {
    open my $fh, '>', "$live_auth/01mailrc.txt.gz"
      or die "[!] Failed to create file: $live_auth/01mailrc.txt.gz";
    close $fh;
}

if ( ! -f "$live_mods/02packages.details.txt.gz" ) {
    open my $fh, '>', "$live_mods/02packages.details.txt.gz"
      or die "[!] Failed to create file: $live_mods/02packages.details.txt.gz";
    close $fh;
}

if ( ! -f "$live_mods/03modlist.data.gz" ) {
    open my $fh, '>', "$live_mods/03modlist.data.gz"
      or die "[!] Failed to create file: $live_mods/03modlist.data.gz";
    printf $fh <<EO3;
File:        03modlist.data
Description: This was once the "registered module list" but has been retired.
        No replacement is planned.
Modcount:    0
Written-By:  PAUSE version 1.005
Date:        Thu, 03 Apr 2014 04:17:11 GMT

package CPAN::Modulelist;
sub data {
return {};
}
1;
EO3
    close $fh;
}

# Help
if ( @ARGV == 0 ) {
    print <<EOH;
pcpan -- Private CPAN manager

Retrieves dependencies for provided CPAN module and updates local CPAN
server with retrieved modules.

Usage: $0 [ <CPAN::Module> <CPAN::Module> .. <CPAN::Module> ]

EOH

    exit;
}

# Main
# Modules that don't have a tarball with their name
my %manual;

# Change to our download directory
chdir $temp_dir
  or die '[!] Could not change to temp directory.';

# Define our configuration location
$ENV{MCPANI_CONFIG} = "$mini_conf";

# Process the provided arguments
while ( @ARGV > 0 ) {

    # Process current argument
    my $target_mod = shift @ARGV;

    # Find dependencies
    printf "[+] [%s] Determining dependencies...\n", $target_mod;

    # Suppress depenecies issues
    open(CPERR, ">&STDERR");
    open(STDERR, '>', '/dev/null');
    
    # Retrieve dependencies
    my @deps = CPAN::FindDependencies::finddeps($target_mod);

    if (!@deps) {
        printf "[!] No dependencies found for '%s', did you spell it correctly?\n", $target_mod;
        exit 255;
    }
    
    # Turn off suppression
    close(STDERR);
    open(STDERR, ">&CPERR");
    close(CPERR);

    # Retrieve the dependencies
    printf "[#] [%s] Beginning\n", $target_mod;
    for (@deps) {
        
        # Dependency module name
        my $dep = $_->name();

        # Get full path name and version, send STDOUT to /dev/null if description is missing
        my @cpan_out = `cpan -D $dep 2>/dev/null`;

        # CPAN filename syntax
        my $mod_name;
        if ( $dep =~ /::/ ) {
            ( $mod_name = $dep ) =~ s/::/-/g;
        }
        else {
            $mod_name = $dep;
        }
        
        # Extract CPAN filename
        my @cpan_filename = grep /^\s+\w\/\w{2}\/\w+\/\Q$mod_name\E-[\d\.]+\.(tar\.gz|zip)$/, @cpan_out;

        # If there is no filename assume its a core module
        if ( ! @cpan_filename ) {
            chomp ( my @cpan_filename = grep /^\s+\w\/\w{2}\/\w+\/.*-[\d\.]+\.(tar\.gz|zip)$/, @cpan_out );
            $cpan_filename[0] =~ s/\s//g;
            printf "[?] [$dep] $cpan_filename[0]\n";
            $manual{$dep} = $cpan_filename[0];
            next;
        }

        # Extract basename from CPAN path
        my @cpan_path = split /\//, $cpan_filename[0];
        my $mod_file = $cpan_path[3];
        chomp $mod_file;

        # Skip if we already have it
        if ( -f "$stag_priv/$mod_file" and -f "$live_priv/$mod_file" ) {
            printf "[ ] [%s] Already have\n", $dep;
            next;
        }
        
        # Download dependency tarball
        printf "[+] [%s] Downloading archive\n", $dep;
        `cpan -g $dep 2>&1 >/dev/null`;
        
        # Die if we failed to download it, cpan uses exit codes liberally
        if ( ! -f $mod_file ) {
            die "[!] Failed to download archive for '$dep'";
        }
        
        # Extract the version number, used when pushing to private CPAN
        ( my $mod_ver = $mod_file ) =~ s/-([\d\.]+)\.(tar\.gz|zip)$/$1/;
        
        # Staging the module to be injected into our private CPAN
        printf "[*] [%s] Staging\n", $dep;
        my @add_mod = ( 'mcpani', '--add', '--module', "$dep", '--authorid', "$priv_auth", '--modversion',
          "$mod_ver", '--file', "$mod_file" );
        system @add_mod
          and die "[!] Failed to add '$dep': $!";

        # Inject the module into our private CPAN
        printf "[*] [%s] Injecting\n", $dep;
        my @inject_mod = ( 'mcpani', '--inject' );
        system @inject_mod
          and die "[!] Failed to inject: $!";

        # Remove the source tarball from temp directory
        printf "[-] [%s] Removing source\n", $dep;
        unlink $mod_file
          or die "[!] Failed to remove '$mod_file': $!";
    }

    # Complete
    printf "[#] [%s] Finished\n", $target_mod;

}

# Sync to sv-opsmgr
if ( ! -f "$priv_key" ) {
    die '[!] Cannot sync, SSH key not present'
}
printf "[*] Syncing to live server\n";
my @rsync_out = `rsync -a -e "ssh -i $priv_key" $mini_live/ $priv_user\@$priv_server:$priv_path`;

# Report mismatches
if (%manual) {
    printf "The following reported different filenames:\n";
    for ( keys %manual ) {
        printf "[?] %s belongs to %s\n", $_, $manual{$_};
    }
}

# Sucess
printf "[+] Finished\n";
