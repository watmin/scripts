#!/usr/bin/perl
#: Title       : genpass.pl
#: Location    : /usr/local/bin/genpass
#: Version     : 1.2
#: Author      : Shields
#: Description : Strong password generator

#: Change log
#: 1.1         : Added checks for character repetiveness
#: 1.1         : Added checks for character concurrency
#: 1.1         : Added sanity checks for parameters
#: 1.1         : Added verbose to show rejected passwords
#: 1.2         : Added optional secure random generator

use strict;
use warnings;
use Getopt::Long;

# Use cryptographically secure generator if present
if ( eval { require Math::Random::Secure ; } ) {
    Math::Random::Secure->import("irand");
}

# Help
sub help {
    printf <<EOF;

genpass -- Generates a password
Usage: genpass [parameters]

Parameters:
  -U|--upper    Required number of uppercase characters
  -L|--lower    Required number of lowercase characters
  -S|--special  Required number of special characters
  -D|--digit    Required number of number characters
  -R|--repeat   Limit number of repeatable charachers
  -C|--concur   Limit number of concurrent characters
  -l|--length   Required length of password
  -c|--count    Number of passwords generated

Options:
  -h|--help     Shows this message
  -v|--verbose  Shows rejected passwords

Defaults:
genpass -U2 -L2 -S1 -D3 -R2 -C2 -l16 -c1

Warnings:
I wouldn't set the required parameter values greater than 3 for under 32 character passwords, 5 for under 128.
I also wouldn't set repeat lower than 4 for 64 character passwords, 5 for 128.
Use at your own discretion.

EOF
    exit $_[0];
}

# Generate password
sub genpass {
    my $length     = $_[0];
    my $char_set   = $_[1];
    my $char_count = @{$char_set};
    my $passwd;
    for ( my $i = 0 ; $i < $length ; $i++ ) {
        if ( defined ( &irand ) ) {
            $passwd .= $$char_set[ int( irand($char_count) ) ];
        } else {
            $passwd .= $$char_set[ int( rand($char_count) ) ];
        }
    }
    return $passwd;
}

# Handle arguments
my %args;
Getopt::Long::Configure('bundling');
GetOptions(
    'h|help'      => \$args{help},
    'v|verbose'   => \$args{verbose},
    'U|upper=i'   => \$args{upper},
    'L|lower=i'   => \$args{lower},
    'S|special=i' => \$args{specl},
    'D|digit=i'   => \$args{digit},
    'R|repeat=i'  => \$args{repet},
    'C|concur=i'  => \$args{concr},
    'l|length=i'  => \$args{length},
    'c|count=i'   => \$args{count}
) or help(1);

if ( defined $args{help} ) { help(0) }

# Assign defaults
if ( !defined $args{upper} )  { $args{upper}  = 2 }
if ( !defined $args{lower} )  { $args{lower}  = 2 }
if ( !defined $args{specl} )  { $args{specl}  = 1 }
if ( !defined $args{digit} )  { $args{digit}  = 3 }
if ( !defined $args{repet} )  { $args{repet}  = 2 }
if ( !defined $args{concr} )  { $args{concr}  = 2 }
if ( !defined $args{length} ) { $args{length} = 16 }
if ( !defined $args{count} )  { $args{count}  = 1 }

# Warnings
if ( $args{repet} < 1 ) { print "Repeated characters was set to 0, this is going to fail...\n"; help(10) }
if ( $args{concr} < 1 ) { print "Character concurrency was set to 0, this isn't going to yield anything...\n"; help(10) }
if ( $args{upper} + $args{lower} + $args{specl} + $args{digit} > $args{length} ) {
    print "Password length cannot support parameters, exiting...\n";
    help(10);
}

# Set lower limit on character concurrency
$args{concr}++;

# Character lists
my @upper = ( 'A' .. 'Z' );
my @lower = ( 'a' .. 'z' );
my @specl = ( '!', '@', '#', '$', '%', '^', '&', '*', ',', '.', '<', '>', '_', '-', '+', '=', '/' );
my @digit = ( 0 .. 9 );

# Pattern definitions
my $upper_pattern = '.*[A-Z]';
my $lower_pattern = '.*[a-z]';
my $specl_pattern = '.*[\!\@\#\$\%\^\&\*\,\.\<\>\_\-\+\=\/]';
my $digit_pattern = '.*[0-9]';

# Define final character list and password strength requirement
my @chars;
my $strength = '^';
if ( $args{upper} ) {
    push( @chars, @upper );
    $strength .= '(?=' . ( $upper_pattern x $args{upper} ) . ')';
}
if ( $args{lower} ) {
    push( @chars, @lower );
    $strength .= '(?=' . ( $lower_pattern x $args{lower} ) . ')';
}
if ( $args{specl} ) {
    push( @chars, @specl );
    $strength .= '(?=' . ( $specl_pattern x $args{specl} ) . ')';
}
if ( $args{digit} ) {
    push( @chars, @digit );
    $strength .= '(?=' . ( $digit_pattern x $args{digit} ) . ')';
}
$strength .= '.{1,}$';

# Generate specified passwords
my $max_tries = 10000;
my $cur_tries = 0;
my $pass;
my $iter = 0;
while ( $iter < $args{count} ) {

    # Bail if we fail too much
    if ( $cur_tries > $max_tries ) {
        print "Failed to generate a password that met the required parameters...\n";
        help(2);
    }

    # Prime conditions for success
    my $str = 0;
    my $rpt = 0;
    my $cnc = 0;

    # Check if the password matches our strength requirement
    $pass = genpass( $args{length}, \@chars );
    if ( $pass =~ m/$strength/ ) {
        $str = 1;
    } else {
        print "DEBUG: rejected `$pass' for not meeting required characters\n" if $args{verbose};
    }

    my @split_pass = split //, $pass;

    # Check if the password falls below our repeated characters limit
  RPT: while ( $pass =~ /(.)/g ) {
        my $char  = $1;
        my $check = 0;
        for (@split_pass) {
            last RPT if $rpt == 1;
            if ( $check > $args{repet} ) {
                print "DEBUG: rejected `$pass' for too many repeated characters\n" if $args{verbose};
                $rpt = 1;
            }
            $check++ if $char =~ /\Q$_\E/;
        }
    }

    # Check if password falls below concurrent character limit
  CNC: while ( $pass =~ /(.)/g ) {
        last CNC if $cnc == 1;
        my $char = $1;
        if ( $pass =~ /(\Q$char\E){$args{concr},}/ ) {
            print "DEBUG: rejected `$pass' for too many concurrent characters\n" if $args{verbose};
            $cnc = 1;
        }
    }

    # Print the password if it meets conditions
    if ( ( $str == 1 ) and ( $rpt == 0 ) and ( $cnc == 0 ) ) {
        printf "%s\n", $pass;
        $iter++;
    }
    else {
        $cur_tries++;
    }
}

