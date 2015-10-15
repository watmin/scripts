#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_mysql_rows.pl
#: Version : 2.1
#: Path    : /usr/local/nagios/libexec/check_mysql_rows.pl
#: Params  : Database, optional table name
#: Desc    : Outputs database row count and disk consumption
#: Changes :
#:         : 2.0
#:         : Completely rewritten
#:         : 2.1
#:         : Added database error handling

use strict;
use warnings;

use DBI;
use Getopt::Long;

# Help if we don't have args
if (!@ARGV) {
    help(0);
}

# Handle arguments
my %args;
GetOptions(
    'h|help'       => \$args{help},
    'd|database=s' => \$args{database},
    't|table=s'    => \$args{table},
) or help(1);

# Bail if we don't have a database
if (!$args{database}) {
    printf "Missing required arguments\n";
    help(255);
}

# Get table stats
if ($args{table}) {
    table( $args{database}, $args{table} );
}

# Get database stats
else {
    database($args{database})
}

# Subs

# Help
sub help {
    my ( $ec ) = @_;
    printf <<EOF;
check_mysql_rows.pl -- Prints row count and disk size for a given database, optional table

Usage: check_mysql_rows.pl -d <database> [-t <table>]

  -d|--database        Target database
  -t|--table           Target table

EOF
    exit $ec;
}

# Connection configuration
sub con {
    my $def = '/path/to/.my.cnf';
    my $dsn = "DBI:mysql:mysql;host=localhost;mysql_read_default_file=$def;";
    my $db_user = undef;
    my $db_pass = undef;
    return ( $dsn, $db_user, $db_pass );
}


# Retrieve database stats
sub database {
    my ( $database ) = @_;
    my ( $dsn, $db_user, $db_pass ) = con;
    my $get_rows = "select table_rows,data_length,index_length from information_schema.tables where table_schema = '$database'";
    
    my $dbh = DBI->connect($dsn, $db_user, $db_pass, { PrintError => 0 }) or ( print "[!] $DBI::errstr\n" and exit 2 );
    my $result_ref = $dbh->selectall_arrayref($get_rows);
    $dbh->disconnect;

    if (!$result_ref) {
        print "[!] Received no results\n";
        exit 2;
    }

    my ( $rows, $data, $index ) = ( 0, 0, 0 );
    for (@$result_ref) {
        $rows += $_->[0];
        $data += $_->[1];
        $index += $_->[2];
    }

    $data = int( $data / ( 1024 ** 2 ) );
    $index = int( $index / ( 1024 ** 2 ) );

    return_vals( $rows, $data, $index, $database );
}

# Retrieve table stats
sub table {
    my ( $database, $table ) = @_;
    my ( $dsn, $db_user, $db_pass ) = con;
    my $get_rows = "select table_rows,data_length,index_length from information_schema.tables where table_schema = '$database' and table_name = '$table'";
    
    my $dbh = DBI->connect($dsn, $db_user, $db_pass, { PrintError => 0 }) or ( print "[!] $DBI::errstr\n" and exit 2 );
    my $sth = $dbh->prepare($get_rows);
    $sth->execute;
    my @result_array = $sth->fetchrow_array;
    $sth->finish();
    $dbh->disconnect;

    if (!@result_array) {
        print "[!] Received no results\n";
        exit 2;
    }
    
    my $rows = $result_array[0];
    my $data = int( $result_array[1] / ( 1024 ** 2 ) );
    my $index = int( $result_array[2] / ( 1024 ** 2 ) );

    return_vals( $rows, $data, $index, $database, $table );
}

# Print the stats
sub return_vals {
    my ( $rows, $data, $index, $database, $table ) = @_;

    my $total = $data + $index;

    if ($table) {
        printf "[%s.%s] Rows: %i, Data: %iMB, Index: %iMB, Total: %iMB|rows=%i data=%iMB index=%iMB total=%iMB\n",
          $database, $table, $rows, $data, $index, $total, $rows, $data, $index, $total;
    }
    else {
        printf "[%s] Rows: %i, Data: %iMB, Index: %iMB, Total: %iMB|rows=%i data=%iMB index=%iMB total=%iMB\n",
          $database, $rows, $data, $index, $total, $rows, $data, $index, $total;
    }
}
