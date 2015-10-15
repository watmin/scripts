#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_cb.pl
#: Version : 1.1
#: Path    : /usr/lib/nagios/plugins/check_cb.pl
#: Params  : See --help
#: Desc    : Reports Couchbase statistics

use strict;
use warnings;

use Getopt::Long;
use JSON::XS;
use LWP::UserAgent;
use HTTP::Request;

# Script vars
my $default_bucket = 'smartvault-data';
my $exit_ok        = 0;
my $exit_warn      = 1;
my $exit_crit      = 2;
my $exit_unkn      = 3;

# Help if no args
if ( !@ARGV ) { help(0) }

# Handle arguments
my %args;
GetOptions(
    'h|help'       => \$args{help},
    'H|host=s'     => \$args{host},
    'N|node=s'     => \$args{node},
    'B|bucket=s'   => \$args{buck},
    'V|value=s'    => \$args{stat},
    'W|warning=s'  => \$args{warn},
    'C|critical=s' => \$args{crit},
    'user=s'       => \$args{user},
    'pass=s'       => \$args{pass}
) or help(1);

if ( $args{help} ) { help(0) }

# Bail if params are not provided
unless ( !$args{host} or ( !$args{node} or !$args{buck} ) or !$args{stat} ) {
    print "[!] Must supply host, node or bucket, and value.\n";
    help(1);
}

# Set the target type
my $type;
if ( $args{node} and $args{buck} ) {
    print "[!] Cannot supply both node and bucket targets\n";
    exit $exit_unkn;
}
elsif ( $args{node} ) {
    $type = 'node';
}
elsif ( $args{buck} ) {
    $type = 'bucket';
}

# Default warnings and criticals
if ( !$args{warn} ) { $args{warn} = 0 }
if ( !$args{crit} ) { $args{crit} = 0 }

# Main

my $decoded;    # Empty container for JSON object
my $status    = 'OK';       # Assume everything is OK
my $exit_code = $exit_ok;

# Node commands
if ( $args{node} ) {

    # Bail if requested value is not for a node
    if ( $args{stat} !~ /^node\./ ) {
        print "[!] Invalid statistics for node: '$args{stat}'\n";
        exit $exit_unkn;
    }

    # Current node connections
    if ( $args{stat} =~ /^node\.curr_connections$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{node}, $args{user}, $args{pass} );
        my $curr_connections = get_avg( $decoded->{op}->{samples}->{curr_connections} );
        if ( $args{warn} and $args{crit} ) {
            if ( $curr_connections > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $curr_connections > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Current connections: %.02f/s|curr_connections=%.02f;%i;%i\n",
          $status, $args{node}, $curr_connections, $curr_connections, $args{warn}, $args{crit};
        exit $exit_code;
    }
    else {
        print "[!] Invalid node value: '$args{stat}'\n";
        exit $exit_unkn;
    }
}

# Bucket commands
elsif ( $args{buck} ) {

    # Bail if requested value is not for a bucket
    if ( $args{stat} !~ /^bucket\./ ) {
        print "[!] Invalid statistics for bucket: '$args{stat}'";
        exit $exit_unkn;
    }

    # Bucket operations per second
    elsif ( $args{stat} =~ /^bucket\.ops$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $ops = get_avg( $decoded->{op}->{samples}->{ops} );
        if ( $args{warn} and $args{crit} ) {
            if ( $ops > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $ops > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Operations per second: %.02f/s|ops=%.02f;%i;%i\n", $status, $args{buck}, $ops, $ops, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket view operations per second
    elsif ( $args{stat} =~ /^bucket\.views_ops$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $views_ops = get_avg( $decoded->{op}->{samples}->{couch_views_ops} );
        if ( $args{warn} and $args{crit} ) {
            if ( $views_ops > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $views_ops > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Views operations per second: %.02f/s|views_ops=%.02f;%i;%i\n",
          $status, $args{buck}, $views_ops, $views_ops, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket current items
    elsif ( $args{stat} =~ /^bucket\.curr_items$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $curr_items = get_avg( $decoded->{op}->{samples}->{curr_items} );
        if ( $args{warn} and $args{crit} ) {
            if ( $curr_items > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $curr_items > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Current items: %.02f/s|curr_items=%.02f;%i;%i\n",
          $status, $args{buck}, $curr_items, $curr_items, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Resident item ratio
    elsif ( $args{stat} =~ /^bucket\.resident_items_ratio$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $resident_items_ratio = get_avg( $decoded->{op}->{samples}->{vb_active_resident_items_ratio} );
        if ( $args{warn} and $args{crit} ) {
            if ( $resident_items_ratio < $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $resident_items_ratio < $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Resident item ratio: %.2f%%|resident_items_ratio=%.2f%%;%i;%i;0;100\n",
          $status, $args{buck}, $resident_items_ratio, $resident_items_ratio, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Memory Headroom
    elsif ( $args{stat} =~ /^bucket\.memory_headroom$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $high_mem        = get_avg( $decoded->{op}->{samples}->{ep_mem_high_wat} );
        my $mem_used        = get_avg( $decoded->{op}->{samples}->{mem_used} );
        my $memory_headroom = int( ( $high_mem - $mem_used ) / 1024**2 );
        if ( $args{warn} and $args{crit} ) {
            if ( $memory_headroom < $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $memory_headroom < $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Memory Headroom: %iMb|memory_headroom=%iMB;%i;%i\n",
          $status, $args{buck}, $memory_headroom, $memory_headroom, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket cache miss ratio
    elsif ( $args{stat} =~ /^bucket\.cache_miss$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $fetched    = get_avg( $decoded->{op}->{samples}->{ep_bg_fetched} );
        my $got        = get_avg( $decoded->{op}->{samples}->{cmd_get} );
        my $cache_miss = eval { $fetched / ( $got * 100 ) };
        if ($@) { $cache_miss = 0 }
        if ( $args{warn} and $args{crit} ) {
            if ( $cache_miss > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $cache_miss > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Cache miss ratio: %.2f%%|cache_miss=%.2f%%;%i;%i;0;100\n",
          $status, $args{buck}, $cache_miss, $cache_miss, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Disk reads per second
    elsif ( $args{stat} =~ /^bucket\.disk_reads$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $disk_reads = get_avg( $decoded->{op}->{samples}->{ep_bg_fetched} );
        if ( $args{warn} and $args{crit} ) {
            if ( $disk_reads > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $disk_reads > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Disk reads per second: %.02f/s|disk_reads=%.02f;%i;%i\n",
          $status, $args{buck}, $disk_reads, $disk_reads, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Ejections
    elsif ( $args{stat} =~ /^bucket\.ejections$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $ejections = get_avg( $decoded->{op}->{samples}->{ep_num_value_ejects} );
        if ( $args{warn} and $args{crit} ) {
            if ( $ejections > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $ejections > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Ejections: %.02f/s|ejections=%.02f;%i;%i\n", $status, $args{buck}, $ejections, $ejections, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Disk write queue
    elsif ( $args{stat} =~ /^bucket\.disk_write_queue$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $disk_write_queue = get_avg( $decoded->{op}->{samples}->{disk_write_queue} );
        if ( $args{warn} and $args{crit} ) {
            if ( $disk_write_queue > $args{crit} ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( $disk_write_queue > $args{warn} ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: Disk write queue: %.02f/s|disk_write_queue=%.02f;%i;%i\n",
          $status, $args{buck}, $disk_write_queue, $disk_write_queue, $args{warn}, $args{crit};
        exit $exit_ok;
    }

    # Bucket Out of memory errors
    elsif ( $args{stat} =~ /^bucket\.oom_errors$/ ) {
        $decoded = get_stats( $type, $args{host}, $args{buck}, $args{user}, $args{pass} );
        my $oom_errors     = get_avg( $decoded->{op}->{samples}->{ep_oom_errors} );
        my $oom_tmp_errors = get_avg( $decoded->{op}->{samples}->{ep_tmp_oom_errors} );
        if ( $args{warn} and $args{crit} ) {
            if ( ( $oom_errors > $args{crit} ) or ( $oom_tmp_errors > $args{crit} ) ) {
                $status    = 'CRITICAL';
                $exit_code = $exit_crit;
            }
            elsif ( ( $oom_errors > $args{warn} ) or ( $oom_tmp_errors > $args{warn} ) ) {
                $status    = 'Warning';
                $exit_code = $exit_warn;
            }
        }
        printf "[%s] %s :: OOM Errors: %.02f/s, OOM Temp Errors: %.02f/s|oom_errors=%.02f;%i;%i oom_tmp_errors=%.02f;%i;%i\n",
          $status, $args{buck}, $oom_errors, $oom_tmp_errors, $oom_errors, $args{warn}, $args{crit}, $oom_tmp_errors, $args{warn}, $args{crit};
        exit $exit_ok;
    }
    else {
        print "[!] Invalid bucket value: '$args{stat}'\n";
        exit $exit_unkn;
    }
}
else {
    print "[?] How did this happen?\n";
    exit $exit_unkn;
}

# Subs

# Help
sub help {
    my ($ec) = @_;
    printf <<EOH;
check_cb.pl -- Report Couchbase statisitics

Usage: check_cb.pl --host <host:port> [--user <username> --pass <password>] \\
         --[bucket|node] <bucket or node:port> --value <desired value>

Parameters:
  -h|--help              Displays this message
  -H|--host              Target machine
  -N|--node              Target node
  -B|--bucket            Target bucket
  -V|--value             Desired value

Options:
  -W|--warning           Warning limit
  -C|--critical          Critical limit
  --user                 Couchbase username
  --pass                 Couchbase password

Values:
  Node:
    node.curr_connections

  Bucket:
    bucket.ops
    bucket.views_ops
    bucket.curr_items
    bucket.resident_items_ratio
    bucket.memory_headroom
    bucket.cache_miss
    bucket.disk_reads
    bucket.ejections
    bucket.disk_write_queue
    bucket.oom_errors
EOH
    exit $ec;
}

# Retrieve JSON for given target
sub get_stats {
    my ( $type, $host, $target, $user, $pass ) = @_;

    # Bucket credentials
    my $creds;
    if ( $user and $pass ) {
        $creds = "${user}:${pass}\@";
    }
    else {
        $creds = '';
    }
    my $url = "http://${creds}${host}";

    # Build the URL
    if ( $type =~ /^node$/ ) {
        $url .= "/pools/default/buckets/$default_bucket/nodes/${target}/stats?zoom=hour";
    }
    elsif ( $type =~ /^bucket$/ ) {
        $url .= "/pools/default/buckets/${target}/stats?zoom=hour";
    }
    else {
        print "[!] Invalid type: $type\n";
        exit $exit_unkn;
    }

    # Get the JSON
    my $agent = LWP::UserAgent->new;
    my $req   = HTTP::Request->new( GET => $url );
    my $res   = $agent->request($req);
    if ( !$res->is_success ) {
        printf "[!] Failed to retrieve JSON: %s\n", $res->status_line;
        exit $exit_unkn;
    }
    my $content = $res->content;
    my $coder   = JSON::XS->new->ascii->pretty->allow_nonref;

    # Return decoded JSON object
    return $coder->decode($content);
}

sub get_avg {
    my ($samples) = @_;

    my $total = 0;

    for ( 0 .. 74 ) {
        $total += $samples->[$_];
    }

    my $average = $total / 75;

    return $average;
}

