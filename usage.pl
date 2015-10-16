#!/usr/bin/perl
#: Author  : Shields
#: Name    : usage.pl
#: Version : 1.3.1
#: Path    : /usr/local/sbin/usage
#: Params  : [directory]
#: Desc    : Reports disk usage statistics for inodes used and space consumed

use strict;
use warnings;
use File::Basename;
use File::Glob qw(bsd_glob);
use Getopt::Long;

# Priming vars
my @dirs;
my %inodes;

# Count all inodes within a directory
sub get_inodes {
    my $dir = "$_[0]";

    # Don't expand metacharacters
    $dir =~ s/\[/\\\[/g;
    $dir =~ s/\]/\\\]/g;
    $dir =~ s/\{/\\\}/g;
    $dir =~ s/\~/\\\~/g;
    $dir =~ s/\*/\\\*/g;
    $dir =~ s/\?/\\\?/g;
    my @files = bsd_glob("$dir/{.*,*}");
    my $count = @files - 2;
    return $count;
}

# Inodes routine
sub inodes {
    my $search    = $_[0];
    my $max_lines = $_[1];
    my $cur_line  = 0;

    # Find all directories
    open(FIND, "find $search -type d \\( -wholename /proc -o -wholename /dev -o -wholename /sys -o -wholename /home/virtfs \\) -prune -o -type d -print 2>/dev/null |");
    while (<FIND>) {
        chomp;
        push @dirs, "$_";
        $inodes{"$_"} = get_inodes("$_");
    }
    close(FIND);

    # Adds counts to parents
    for ( reverse @dirs ) {
        $inodes{ dirname("$_") } += $inodes{"$_"} if exists $inodes{ dirname("$_") };
    }

    # Outputs the counts
    printf "%-12s %s\n", 'Inodes:', 'Directory:';
    for ( sort { $inodes{$b} <=> $inodes{$a} } keys %inodes ) {
        if ( $cur_line == $max_lines ) { exit 0 }
        else {
            printf "%-12s %s\n", $inodes{$_}, $_;
            $cur_line++;
        }
    }

    exit 0;
}

# Size routine
sub size {
    my $search = $_[0];
    my %disk;
    my $max_lines = $_[1];
    my $cur_line  = 0;

    # Perform the raw `du`
    my @raw = `du $search 2>/dev/null`;

    # Parse the raw output
    for (@raw) {
        $_ =~ /(\S*)\s*(.*)/;
        next if ($2 =~ /^\/proc|^\/sys|^\/dev|^\/home\/virtfs/);
        $disk{$2} = $1;
    }

    # Print the formatted output
    printf "%-12s %s\n", 'Disk usage:', 'Directory:';
    for ( sort { $disk{$b} <=> $disk{$a} } keys %disk ) {
        if ( $cur_line == $max_lines ) { exit 0 }
        else {
            my $path = $_;
            my $size = $disk{$path};
            if ( $size > 1073741824 ) {
                $size = sprintf( "%.2fT", $size / 1073741824 );
            }
            elsif ( $size > 1048576 ) {
                $size = sprintf( "%.2fG", $size / 1048576 );
            }
            elsif ( $size > 1024 ) {
                $size = sprintf( "%.2fM", $size / 1024 );
            }
            printf "%-12s %s\n", $size, $path;
            $cur_line++;
        }
    }

    exit 0;
}

# Help message
sub help {
    printf <<EOH;

usage -- Disk usage reporting tool.

Usage: usage.pl [switches] directory
  -h | --help       Shows this message

Required switches:
  -i | --inodes     Reports inodes
  -d | --disk       Reports disk size consumption

Optional switches:
  -l | --lines      Maximum number of lines to display

EOH
    exit $_[0];
}

if ( @ARGV == 0 ) { help(0) }

my %args;
Getopt::Long::Configure('bundling');
GetOptions(
    'h|help'    => \$args{help},
    'i|inodes'  => \$args{inodes},
    'd|disk'    => \$args{disk},
    'l|lines=s' => \$args{lines}
) or help(1);

if ( $args{help} ) { help(0) }

if ( @ARGV > 1 ) { help(1) }

my $search_path;
if ( @ARGV == 0 or $ARGV[0] =~ /^\.\/?$/ ) {
    $search_path = $ENV{PWD};
}
else {
    $search_path = $ARGV[0];
}
$search_path =~ s/(.+)\/$/$1/;

if ( ! -d $search_path) {
    print "$search_path is not a directory...\n";
    help(2);
}

if ( !defined $args{lines} ) { $args{lines} = 40 }

if ( $args{inodes} ) {
    inodes( $search_path, $args{lines} );
}

if ( $args{disk} ) {
    size( $search_path, $args{lines} );
}

if ( ! defined $args{inodes} and ! defined $args{disk} ) {
    print "You need to give me a search type...\n";
    help(10);
}

help(255);

