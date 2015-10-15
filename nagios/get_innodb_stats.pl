#!/usr/bin/perl
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : get_innodb_stats.pl
#: Version : 2.1
#: Path    : /data/performance/get_innodb_stats.pl
#: Params  : None
#: Desc    : Outputs InnoDB data points over time
#: Changes :
#: 2.0     : Completely rewritten
#: 2.1     : Updated InnoDB timestamp parse

use strict;
use warnings;

use DBI;
use Storable;
use Time::Piece;

# Script vars
my $def = '/path/to/.my.cnf';
my $dsn = "DBI:mysql:mysql;host=localhost;mysql_read_default_file=$def;";
my $db_user = undef;
my $db_pass = undef;
my $perf_dir = '/opt/sv/performance/';
my $global_store = "${perf_dir}global_store";
my $innodb_store = "${perf_dir}innodb_store";

# Retrieve previous values
my $previous_global = retrieve($global_store);
my $previous_innodb = retrieve($innodb_store);

# Get current status
my ( $global, $innodb, $time_interval, $failure ) = get_status( $dsn, $db_user, $db_pass, $previous_global, $previous_innodb );

# Ship data points
get_innodb_cache( $global, $previous_global, $failure );
get_innodb_queries( $innodb, $failure );
get_row_ops( $global, $previous_global, $failure );
get_data_stats( $global, $previous_global, $failure );
get_pending_stats( $global, $previous_global, $failure );
get_sema_mutex( $global, $previous_global, $failure );
get_sema_rwshared( $global, $previous_global, $failure );
get_sema_rwexcl( $global, $previous_global, $failure );

# Finish
if ($failure) { die "[!] $failure\n" }
else          { exit 0 }

# Subs

# Connecet to MySQL and retrieve global and engine status
sub get_status {
    my ( $dsn, $db_user, $db_pass, $pre_global, $pre_innodb ) = @_;

    # Setup queries
    my $global_status = 'SHOW GLOBAL STATUS';
    my %global_hash;
    my $innodb_status = 'SHOW ENGINE INNODB STATUS';
    my @innodb_array;

    # Establish MySQL connection
    my $mysql_conn_fail = 0;
    my $dbh = DBI->connect( $dsn, $db_user, $db_pass, { PrintError => 0 } ) or ( $mysql_conn_fail = $DBI::errstr );

    if ( !$mysql_conn_fail ) {

        # Retrieve SHOW GLOBAL STATUS
        %global_hash = map { $_->[0] => $_->[1] } @{ $dbh->selectall_arrayref($global_status) };

        # Retrieve SHOE ENGINE INNODB STATUS
        my $sth = $dbh->prepare($innodb_status);
        $sth->execute();
        @innodb_array = $sth->fetchrow_array;

        # Close database connection
        $sth->finish();
        $dbh->disconnect;

        # Extract InnoDB status from result set
        my $innodb_string = $innodb_array[2];
        my %innodb_hash;

        # Extract InnoDB values from result set
        $innodb_string =~ /(\d{2})-(\d{2})-(\d{2}) +(\S+) (\S{12}) INNODB MONITOR OUTPUT/;
        $innodb_hash{timestamp} = Time::Piece->strptime( "$1/$2/$3 $4", "%Y/%m/%d %H:%M:%S" )->epoch;

        $innodb_string =~ /(\d+) quer(y|ies) inside InnoDB, (\d+) quer(y|ies) in queue/;
        $innodb_hash{innodb_queries} = $1;
        $innodb_hash{innodb_queued}  = $3;

        # Store values
        store( \%global_hash, $global_store );
        store( \%innodb_hash, $innodb_store );

        # Generate Nagios data points
        my $time_interval = $innodb_hash{timestamp} - $pre_innodb->{timestamp};

        return ( \%global_hash, \%innodb_hash, $time_interval, $mysql_conn_fail );
    }
    else {

        my %global_fail   = ();
        my %innodb_fail   = ();
        my $fail_interval = 0;

        return ( \%global_fail, \%innodb_fail, $fail_interval, $mysql_conn_fail );
    }
}

# Execute NSCA client
sub push_stats {
    my ( $title, $status, $pretty, $perf ) = @_;

    my $nsca_check = '/usr/local/nagios/libexec/forward_service_check';

    chomp( my $host = `hostname` );
    my @nsca_args = ( $nsca_check, $host, "$title", $status, "${pretty}${perf}" );

    system @nsca_args;
}

# Return differential over time
sub get_rate {
    my ( $current, $previous ) = @_;

    my $result = ( $current - $previous ) / $time_interval;

    return $result;
}

# Return Innodb Cache statistics
sub get_innodb_cache {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB Cache';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_hits = $cur->{Innodb_buffer_pool_read_requests};
        my $pre_hits = $pre->{Innodb_buffer_pool_read_requests};
        my $cur_miss = $cur->{Innodb_buffer_pool_reads};
        my $pre_miss = $pre->{Innodb_buffer_pool_reads};

        my $cache_hits = get_rate( $cur_hits, $pre_hits );
        my $cache_miss = get_rate( $cur_miss, $pre_miss );
        my $cache_effi = eval { ( 1 - ( $cur_miss - $pre_miss ) / ( $cur_hits - $pre_hits ) ) * 100 };
        if ($@) { $cache_effi = 0 }

        if ( $cache_effi < 99.00000 and $cache_effi > 95.00000 ) {
            $status = 'WARNING';
        }
        elsif ( $cache_effi < 95.00000 or $cache_effi > 100.00000 ) {
            $status = 'CRITICAL';
        }

        $pretty = sprintf '[%s] %s :: Hits: %.2f/s, Misses: %.2f/s, Efficiency: %.5f%%', $status, $title, $cache_hits, $cache_miss, $cache_effi;
        $perf = sprintf '|innodb_cache_hits=%.2f innodb_cache_misses=%.2f innodb_cache_efficiency=%.5f',
          $cache_hits, $cache_miss, $cache_effi;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB Query statistics
sub get_innodb_queries {
    my ( $cur, $fail ) = @_;

    my $title  = 'InnoDB Queries';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_queries = $cur->{innodb_queries};
        my $cur_queued  = $cur->{innodb_queued};

        if ( ( $cur_queries > 35 and $cur_queries < 44 ) or ( $cur_queued > 1 and $cur_queued < 2 ) ) {
            $status = 'WARNING';
        }
        elsif ( $cur_queries > 45 or $cur_queued > 2 ) {
            $status = 'CRITICAL';
        }

        $pretty = sprintf '[%s] %s :: Queries: %i, Queued: %i', $status, $title, $cur_queries, $cur_queued;
        $perf = sprintf '|innodb_queries=%i innodb_queued=%i', $cur_queries, $cur_queued;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return Row Operations statistics
sub get_row_ops {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB Row Operations';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_inserts = $cur->{Innodb_rows_inserted};
        my $pre_inserts = $pre->{Innodb_rows_inserted};
        my $cur_updates = $cur->{Innodb_rows_updated};
        my $pre_updates = $pre->{Innodb_rows_updated};
        my $cur_deletes = $cur->{Innodb_rows_deleted};
        my $pre_deletes = $pre->{Innodb_rows_deleted};
        my $cur_reads   = $cur->{Innodb_rows_read};
        my $pre_reads   = $pre->{Innodb_rows_read};

        my $inserts = get_rate( $cur_inserts, $pre_inserts );
        my $updates = get_rate( $cur_updates, $pre_updates );
        my $deletes = get_rate( $cur_deletes, $pre_deletes );
        my $reads   = get_rate( $cur_reads,   $pre_reads );

        $pretty = sprintf '[%s] %s :: Inserts: %.2f/s, Updates: %.2f/s, Deletes: %.2f/s, Reads: %.2f/s',
          $status, $title, $inserts, $updates, $deletes, $reads;
        $perf = sprintf '|innodb_rows_inserts=%.2f innodb_rows_updates=%.2f innodb_rows_deletes=%.2f innodb_rows_reads=%.2f',
          $inserts, $updates, $deletes, $reads;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB Data Statistics
sub get_data_stats {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB Data Statistics';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_fsyncs = $cur->{Innodb_data_fsyncs};
        my $pre_fsyncs = $pre->{Innodb_data_fsyncs};
        my $cur_reads  = $cur->{Innodb_data_reads};
        my $pre_reads  = $pre->{Innodb_data_reads};
        my $cur_writes = $cur->{Innodb_data_writes};
        my $pre_writes = $pre->{Innodb_data_writes};

        my $fsyncs = get_rate( $cur_fsyncs, $pre_fsyncs );
        my $reads  = get_rate( $cur_reads,  $pre_reads );
        my $writes = get_rate( $cur_writes, $pre_writes );

        $pretty = sprintf '[%s] %s :: Fsyncs: %.2f/s, Reads: %.2f/s, Writes: %.2f/s', $status, $title, $fsyncs, $reads, $writes;
        $perf = sprintf '|innodb_data_fsyncs=%.2f innodb_data_reads=%.2f innodb_data_writes=%.2f', $fsyncs, $reads, $writes;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB Pending Statistics
sub get_pending_stats {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB Pending Statistics';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_fsyncs = $cur->{Innodb_data_pending_fsyncs};
        my $pre_fsyncs = $pre->{Innodb_data_pending_fsyncs};
        my $cur_reads  = $cur->{Innodb_data_pending_reads};
        my $pre_reads  = $pre->{Innodb_data_pending_reads};
        my $cur_writes = $cur->{Innodb_data_pending_writes};
        my $pre_writes = $pre->{Innodb_data_pending_writes};

        my $fsyncs = get_rate( $cur_fsyncs, $pre_fsyncs );
        my $reads  = get_rate( $cur_reads,  $pre_reads );
        my $writes = get_rate( $cur_writes, $cur_writes );

        $pretty = sprintf '[%s] %s :: Fsyncs: %.2f/s, Reads: %.2f/s, Writes: %.2f/s', $status, $title, $fsyncs, $reads, $writes;
        $perf = sprintf '|innodb_pending_data_fsyncs=%.2f innodb_pending_data_reads=%.2f innodb_pending_data_writes=%.2f',
          $fsyncs, $reads, $writes;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB Mutex Statistics
sub get_sema_mutex {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB Mutex Statistics';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_spin_waits = $cur->{Innodb_mutex_spin_waits};
        my $pre_spin_waits = $pre->{Innodb_mutex_spin_waits};
        my $cur_rounds     = $cur->{Innodb_mutex_spin_rounds};
        my $pre_rounds     = $pre->{Innodb_mutex_spin_rounds};
        my $cur_os_waits   = $cur->{Innodb_mutex_os_waits};
        my $pre_os_waits   = $pre->{Innodb_mutex_os_waits};

        my $spin_waits = get_rate( $cur_spin_waits, $pre_spin_waits );
        my $rounds     = get_rate( $cur_rounds,     $pre_rounds );
        my $os_waits   = get_rate( $cur_os_waits,   $pre_os_waits );

        $pretty = sprintf '[%s] %s :: Spin waits: %.2f/s, Rounds: %.2f/s, OS Waits: %.2f/s', $status, $title, $spin_waits, $rounds,
          $os_waits;
        $perf = sprintf '|innodb_mutex_spin_waits=%.2f innodb_mutex_rounds=%.2f innodb_mutex_os_waits=%.2f',
          $spin_waits, $rounds, $os_waits;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB RW-shared Statistics
sub get_sema_rwshared {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB RW-shared Statistics';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_lock_spin_waits = $cur->{Innodb_s_lock_spin_waits};
        my $pre_lock_spin_waits = $pre->{Innodb_s_lock_spin_waits};
        my $cur_lock_rounds     = $cur->{Innodb_s_lock_spin_rounds};
        my $pre_lock_rounds     = $pre->{Innodb_s_lock_spin_rounds};
        my $cur_lock_os_waits   = $cur->{Innodb_s_lock_os_waits};
        my $pre_lock_os_waits   = $pre->{Innodb_s_lock_os_waits};

        my $spin_lock_waits = get_rate( $cur_lock_spin_waits, $pre_lock_spin_waits );
        my $lock_rounds     = get_rate( $cur_lock_rounds,     $pre_lock_rounds );
        my $lock_os_waits   = get_rate( $cur_lock_os_waits,   $pre_lock_os_waits );

        $pretty = sprintf '[%s] %s :: Spin waits: %.2f/s, Rounds: %.2f/s, OS Waits: %.2f/s',
          $status, $title, $spin_lock_waits, $lock_rounds, $lock_os_waits;
        $perf = sprintf '|innodb_rw_shared_spin_waits=%.2f innodb_rw_shared_rounds=%.2f innodb_rw_shared_os_waits=%.2f',
          $spin_lock_waits, $lock_rounds, $lock_os_waits;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

# Return InnoDB RW-excl Statistics
sub get_sema_rwexcl {
    my ( $cur, $pre, $fail ) = @_;

    my $title  = 'InnoDB RW-excl Statistics';
    my $status = 'OK';
    my $pretty = '';
    my $perf   = '';

    if ( !$fail ) {
        my $cur_x_lock_spin_waits = $cur->{Innodb_x_lock_spin_waits};
        my $pre_x_lock_spin_waits = $pre->{Innodb_x_lock_spin_waits};
        my $cur_x_lock_rounds     = $cur->{Innodb_x_lock_spin_rounds};
        my $pre_x_lock_rounds     = $pre->{Innodb_x_lock_spin_rounds};
        my $cur_x_lock_os_waits   = $cur->{Innodb_x_lock_os_waits};
        my $pre_x_lock_os_waits   = $pre->{Innodb_x_lock_os_waits};

        my $x_spin_lock_waits = get_rate( $cur_x_lock_spin_waits, $pre_x_lock_spin_waits );
        my $x_lock_rounds     = get_rate( $cur_x_lock_rounds,     $pre_x_lock_rounds );
        my $x_lock_os_waits   = get_rate( $cur_x_lock_os_waits,   $pre_x_lock_os_waits );

        $pretty = sprintf '[%s] %s :: Spin waits: %.2f/s, Rounds: %.2f/s, OS Waits: %.2f/s',
          $status, $title, $x_spin_lock_waits, $x_lock_rounds, $x_lock_os_waits;
        $perf = sprintf '|innodb_rw_excl_spin_waits=%.2f innodb_rw_excl_rounds=%.2f innodb_rw_excl_os_waits=%.2f',
          $x_spin_lock_waits, $x_lock_rounds, $x_lock_os_waits;
    }
    else {
        $status = 'CRITICAL';
        $pretty = $fail;
        $perf   = '';
    }

    push_stats( $title, $status, $pretty, $perf );
}

