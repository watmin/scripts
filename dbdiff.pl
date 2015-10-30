#!/usr/bin/perl
#: Author  : John Shields <john.shields@smartvault.com>
#: Name    : dbdiff.pl
#: Version : 1.0.0
#: Path    : /usr/local/bin/dbdiff
#: Params  : db1.sql db2.sql
#: Options : -h,--help
#: Desc    : Shows the differences between table creates for two database dumps

use strict;
use warnings;

use Getopt::Long qw/:config no_ignore_case/;

if ( !@ARGV ) {
    help(0);
}
elsif ( @ARGV != 2 ) {
    die "Failed to provide database dumps for both databases\n";
}

my %args;
GetOptions(
    'h|help' => \$args{'help'},
);

if ( $args{'help'} ) {
    help(0);
}

my ( $sql1, $sql2 ) = @ARGV;
if ( !-f $sql1 ) {
    die "The provided first database file doesn't exist\n";
}
if ( !-f $sql2 ) {
    die "The provided second database file doesn't exist\n";
}

my %sql1_tables = get_tables($sql1);
my %sql2_tables = get_tables($sql2);

for my $key (sort keys %sql1_tables) {
    if ( exists $sql2_tables{$key} ) {
        if ( $sql1_tables{$key} ne $sql2_tables{$key} ) {
            print "The table '$key' doesn't match\n\n";

            my ( $s1_c, $s1_p, $s1_u, $s1_k, $s1_e ) = table_hashes( $sql1_tables{$key} );
            my ( $s2_c, $s2_p, $s2_u, $s2_k, $s2_e ) = table_hashes( $sql2_tables{$key} );

            print_diffs( $s1_c, $s2_c, 'column' );
            print_diffs( $s1_p, $s2_p, 'primary key' );
            print_diffs( $s1_u, $s2_u, 'unique key' );
            print_diffs( $s1_k, $s2_k, 'key' );
            print_diffs( $s1_e, $s2_e, 'engine' );

            print "Here is the raw diff:\n\n";
            print "--- $sql1\n";
            print "+++ $sql2\n";
            system( "bash", "-c", "diff -bur <(echo '$sql1_tables{$key}') <(echo '$sql2_tables{$key}') | tail -n +3" );
            print '#' x 80, "\n\n";
        }
    }
    else {
        print "The table '$key' doesn't exist\n\n";
        print '#' x 80, "\n\n";
    }
}

exit;

sub help {
    my ($exit_code) = @_;

    print <<EOH;
dbdiff -- Prints the differences in CREATE TABLE between two MySQL dumps

Usage: dbdiff <db1.sql> <db2.sql>

Options:
  -h,--help     Shows this output

Tips:
  Create the database dump with `mysqldump -d <db-name>` > db-name.sql
  This will create a dump of only the table creates which is all this
    script will parse. It is best to suppress row data.

John Shields - SmartVault Corporation - 2015
EOH

    exit $exit_code;
}

sub get_tables {
    my ($file) = @_;
    
    my ( $temp, %hash );

    open my $file_h, '<', $file or die "Failed to process '$file': $!\n";
    while (<$file_h>) {
        my $line = $_;
        if ( $line =~ /^CREATE/../^\) ENGINE.+;$/ ) {
            $temp .= $line;
            if ( $temp =~ /(?<=CREATE TABLE \`)(\S+)(?=\`)/ ) {
                my $key = $1;
                $hash{$key} = $temp;
            }
        }
        else {
            $temp = undef;
        }

    }
    close $file_h;

    return %hash;
}

sub table_hashes {
    my ($create) = @_;

    my ( %columns, %primary_key, %unique_keys, %keys, %engine );

    my @lines = split /\n/, $create;
    chomp @lines;

    for my $line (@lines) {
        if ( $line =~ /^\s+\`(\S+)\`/ ) {
            $columns{$1} = $line;
        }

        if ( $line =~ /^\s+PRIMARY KEY \(\`(\S+)\)\`/ ) {
            $primary_key{$1} = $line;
        }

        if ( $line =~ /^\s+UNIQUE KEY \`(\S+)\`/ ) {
            $unique_keys{$1} = $line;
        }

        if ( $line =~ /^\s+KEY \`(\S+)\`/ ) {
            $keys{$1} = $line;
        }

        if ( $line =~ /^\) ENGINE=(\S+)/ ) {
            $engine{$1} = $line;
        }
    }

    return ( \%columns, \%primary_key, \%unique_keys, \%keys, \%engine );
}

sub print_diffs {
    my ( $hash1, $hash2, $type ) = @_;

    my $len1 = length($sql1);
    my $len2 = length($sql2);
    my $len  = $len1 > $len2 ? $len1 : $len2;
    
    my $diff;
    for my $key (sort keys %{$hash1}) {
        if ( ! exists $hash2->{$key} ) {
            print "The $type '$key' does not exist.\n\n";
        }
        else {
            if ( $hash1->{$key} ne $hash2->{$key} ) {
                $diff++;
                if ( $diff == 1 ) {
                    print "Here are the $type differences:\n\n";
                }   
                print "The $type '$key' differs:\n";
                printf "%-${len}s: %s\n", $sql1, $hash1->{$key};
                printf "%-${len}s: %s\n", $sql2, $hash2->{$key};
            }
        }
    }
    $diff and print "\n";

    return;
}

