#!/usr/bin/perl

use strict;
use warnings;

my ( $first, $second, @bleh ) = @ARGV;

my %first_hash = build_hash($first);
my %second_hash = build_hash($second);

for my $key (sort keys %first_hash) {
    if ( exists $second_hash{$key} ) {
        if ( $first_hash{$key} ne $second_hash{$key} ) {
            print "The table '$key' doesn't match\n";
            print "Here are the column differences:\n";
            my @first_columns = split /\n/, $first_hash{$key};
            my %first_c_h;
            for (@first_columns) {
                chomp;
                if ( m/^\s+\`(\S+)\`/) {
                    $first_c_h{$1} = $_;
                }
            }
            my @second_columns = split /\n/, $second_hash{$key};
            my %second_c_h;
            for (@second_columns) {
                chomp;
                if ( m/^\s+\`(\S+)\`/ ) {
                    $second_c_h{$1} = $_;
                }
            }
            for my $c_key (sort keys %first_c_h) {
                if ( ! exists $second_c_h{$c_key} ) {
                    print "The column '$c_key' doesn't exist\n";
                }
                else {
                    if ( $first_c_h{$c_key} ne $second_c_h{$c_key} ) {
                        print "The column '$c_key' differs:\n";
                        print "$first\t $first_c_h{$c_key}\n";
                        print "$second\t $second_c_h{$c_key}\n";
                        print "\n";
                    }
                }
            }
            print "\n";
            print "Here is the raw diff:\n";
            print "--- $first\n";
            print "+++ $second\n";
            system( "bash", "-c", "diff -bur <(echo '$first_hash{$key}') <(echo '$second_hash{$key}') | tail -n +3" );
            print "\n", "#" x 80, "\n\n";
        }
    }
    else {
        print "The table '$key' doesn't exist\n\n";
        print "#" x 80, "\n\n";
    }
}

sub build_hash {
    my ( $file ) = @_;
    
    my ( $temp, %hash );

    open my $file_h, '<', $file or die "wtf did you do to '$file'?";

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

    return %hash;
}

