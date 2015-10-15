#!/usr/bin/perl
# nagios: -epn
#: Author  : Shields <john.shields@smartvault.com>
#: Name    : check_qnap.pl
#: Version : 1.0.1
#: Path    : /usr/lib/nagios/plugins/check_qnap.pl
#: Params  : See --help
#: Desc    : Reports SNMPv3 values for QNAP
#: ------- :
#: Changes : 
#:         : 1.0.1
#:         : Changed how HDD status and tempurature report
#: ------- : 
#: To do   : Create switches for SNMP vars

use strict;
use warnings;

use Getopt::Long;
use Switch;

# SNMP vars
my $snmp_user = 'snmp_user';
my $auth_type = 'snmp_auth';
my $auth_hash = 'snmp_hash';
my $auth_pass = 'snmp_pass';
my $priv_encr = 'snmp_encr';
my $priv_pass = 'snmp_priv';
my $mib_type = 'NAS-MIB';
my $timeout = 30;
my $snmpget = '/usr/bin/snmpget';

# Help if no args
if (!@ARGV) { help(0) }

# Handle arguments
my %args;
GetOptions(
    'h|help'    => \$args{help},
    'H|host=s'  => \$args{host},
    'V|value=s' => \$args{stat},
) or help(1);

if ($args{help}) { help(0) }

# Die if params are not provided
if ( !$args{host} or !$args{stat} ) {
    die '[!] Must supply both host and value.'
}

# Main
switch ($args{stat}) {
    case 'system_temp' {system_temp($args{host})}
    case 'uptime' {uptime($args{host})}
    case 'cpu_usage' {cpu_usage($args{host})}
    case 'memory_usage' {memory_usage($args{host})}
    case 'hard_drives' {hard_drives($args{host})}
    case 'hdd_temp' {hdd_temp($args{host})}
    case 'volume_status' {volume_status($args{host})}
    case 'volume_usage' {volume_usage($args{host})}
    else { die "Invalid value: '$args{stat}'" }
}

# Subs

# Usage
sub help {
    my ( $ec ) = @_;
    printf <<EOH;
check_qnap.pl -- Reports QNAP SNMPv3 values in Nagios format

Usage: check_qnap.pl --host <qnap_machine> --value <value>

Parameters:
  -h|--help         Displays this message
  -H|--host         Target machine
  -V|--value        Desired value

Values:
  system_temp       Reports system temperatures
  uptime            Reports system uptime
  cpu_usage         Reports CPU usage
  memory_usage      Reports memory usage
  hard_drives       Reports hard drive status
  hdd_temp          Reports hard drive temperatures
  volume_status     Reports volume status
  volume_usage      Reports drive usage
EOH
    exit $ec;
}

# Get SNMP value
sub get_value {
    my ( $host, $value ) = @_;
    my $get = "$snmpget -O vq -v3 -l $auth_type -a $auth_hash -A $auth_pass -x $priv_encr -X $priv_pass -u $snmp_user -m $mib_type -t $timeout $host $value";
    chomp ( my $result = `$get` );
    if ( $? gt 0 ) { die " Failed to retrieve SNMP value: $value" }
    return "$result";
}

# Returns number of drives
sub get_drives {
    my ( $host ) = @_;
    my $value = 'HdNumberEX.0';
    my $num_drives = get_value($host, $value);
    return $num_drives;
}

# Returns number of volumes
sub get_volumes {
    my ( $host ) = @_;
    my $value = 'SysVolumeNumberEX.0';
    my $num_volumes = get_value($host, $value);
    return $num_volumes;
}

# Return system and CPU temperature
sub system_temp {
    my ( $host ) = @_;

    my $prefix = 'OK';
    my $exit_code = 0;

    my $sys_temp = get_value($host, 'SystemTemperatureEX.0');
    my $cpu_temp = get_value($host, 'CPU-TemperatureEX.0');

    # warn at 58, critical at 65
    if ( ( $sys_temp > 65 ) or ( $cpu_temp > 65 ) ) {
        $prefix = 'CRITICAL';
        $exit_code = 2;
    }
    elsif ( ( $sys_temp > 58 ) or ( $cpu_temp > 58 ) ) {
        $prefix = 'WARNING';
        $exit_code = 1;
    }

    printf "[%s] System Temperature: %sC; CPU Temperature: %sC | sys_temp=%s;58;65 cpu_temp=%s;58;65\n",
           $prefix, $sys_temp, $cpu_temp, $sys_temp, $cpu_temp;
    exit $exit_code;
}

# Returns uptime
sub uptime {
    my ( $host ) = @_;

    my $raw_uptime = get_value($host, 'SystemUptimeEX.0');
    my @split_uptime = split /:/, $raw_uptime;
    
    printf "Uptime: %s Days, %s Hours, %s Minutes, %s Seconds\n", @split_uptime;
    exit 0;
}

# Returns CPU usage
sub cpu_usage {
    my ( $host ) = @_;

    my $prefix = 'OK';
    my $exit_code = 0;

    my $cpu_usage = get_value($host, 'SystemCPU-UsageEX.0');

    # Need to determine warnings for this
    if ( $cpu_usage > 90 ) {
        $prefix = 'Critical';
        $exit_code = 2;
    }
    elsif ( $cpu_usage > 75 ) {
        $prefix = 'Warning';
        $exit_code = 1;
    }
    printf "[%s] CPU usage: %s%% | cpu_usage=%s%%;75;90\n",
           $prefix, $cpu_usage, $cpu_usage;
    exit $exit_code;
}

# Return memory usage
sub memory_usage {
    my ( $host ) = @_;

    my $prefix = 'OK';
    my $exit_code = 0;

    my $free_mem = get_value($host, 'SystemFreeMemEX.0');
    my $total_mem = get_value($host, 'SystemTotalMemEX.0');

    my $memory_used = $total_mem - $free_mem;
    my $memory_usage = ( $memory_used / $total_mem ) * 100;

    # Need to determine warnings for this
    printf "[%s] Memory usage: %.2f%% | mem_usage=%.2f%%\n",
           $prefix, $memory_usage, $memory_usage;
    exit $exit_code;
}

# Returns SMART and raid status for all drives
sub hard_drives {
    my ( $host ) = @_;
    my $exit_code = 0;

    my $num_drives = get_drives($host);

    my $drive_status = 'Hard drive status :: ';
    for my $hdd ( 1 .. $num_drives ) {
        my $bad_disk = 0;
        my $tail = ', ';
        my $smart = get_value($host, "HdSmartInfoEX.$hdd");
        
        if ( $smart !~ /^"GOOD"$/ ) {
            $bad_disk = 1;
            $exit_code = 2;
        }

        my $raid = get_value($host, "HdStatusEX.$hdd");
        if ( $raid !~ /^ready$/ ) {
            $bad_disk = 1;
            $exit_code = 2;
        }

        if ($bad_disk) {
            $drive_status .= "Drive [$hdd]: SMART: ${smart} RAID: ${raid}${tail}";
        }
    }

    $drive_status =~ s/, $//;

    if ( $exit_code == 0 ) { $drive_status .= 'Drives OK' }

    printf "%s\n", $drive_status;
    exit $exit_code;
}

# Returns temperatures for all drives
sub hdd_temp {
    my ( $host ) = @_;
    my $exit_code = 0;

    my $num_drives = get_drives($host);

    my $drive_temp = 'HDD temperatures :: ';
    my $temp_perf = '';

    my ( $warning, $critical ) = ( 0, 0 );
    for my $hdd ( 1 .. $num_drives ) {
        my $temp = get_value($host, "HdTemperatureEX.$hdd");
        my $prefix = '';
        my $tail = ', ';

        # warning at 40, critical at 45
        if ( $temp > 45 ) {
            $critical = 1;
            $prefix = '[Critical] ';
        }
        elsif ( $temp > 40 ) {
            $warning = 1;
            $prefix = '[Warning] ';
        }

        $drive_temp .= "Drive [$hdd]: ${prefix}${temp}C${tail}"
          if $temp > 40;
        $temp_perf .= "${hdd}_temp=$temp;40;45 ";
    }
    
    $drive_temp =~ s/, $//;

    if ( $critical ) { $exit_code = 2 }
    elsif ( $warning ) { $exit_code = 1 }

    if ( $exit_code == 0 ) { $drive_temp .= 'Drives OK' }

    printf "%s | %s\n", $drive_temp, $temp_perf;
    exit $exit_code;
}

# Returns volume status
sub volume_status {
    my ( $host ) = @_;
    my $exit_code = 0;
    my $volume_status = 'Volume status :: ';

    my $num_volumes = get_volumes($host);

    for my $volume ( 1 .. $num_volumes ) {
        my $tail = ', ';
        if ( $volume == $num_volumes ) { $tail = '' }
        my $status = get_value($host, "SysVolumeStatusEX.$volume");
        my $prefix = '';
        if ( $status !~ /^"Ready"$/ ) {
            $prefix = '[Critical] ';
            $exit_code = 2;
        }

        $volume_status .= "Volume [$volume]: ${prefix}${status}${tail}";
    }

    print "$volume_status\n";
    exit $exit_code;
}

# Returns volume usage
sub volume_usage {
    my ( $host ) = @_;
    my $exit_code = 0;
    my $volume_usage = 'Volume usage :: ';
    my $volume_perf = '';

    my $num_volumes = get_volumes($host);

    for my $volume ( 1 .. $num_volumes ) {
        my $prefix = '';
        my $tail = ', ';
        if ( $volume == $num_volumes ) { $tail = '' }
        my $volume_free = get_value($host, "SysVolumeFreeSizeEX.$volume");
        my $volume_total = get_value($host, "SysVolumeTotalSizeEX.$volume");
        
        my $used = $volume_total - $volume_free;
        my $usage = sprintf '%.2f', ( $used / $volume_total ) * 100;
        my $free = sprintf '%i', ( $volume_free / 1024 );

        if ( $usage > 90 ) {
            $exit_code = 2;
            $prefix = '[Critical] ';
        }
        elsif ( $usage > 80 ) {
            $exit_code = 1;
            $prefix = '[Warning] ';
        }

        $volume_usage .= "Volume [$volume]: ${prefix}${usage}% Free: ${free} MB${tail}";
        $volume_perf .= "${volume}_usage=${usage}%;80;90 ${volume}_free=${free}MB";
    }

    printf "%s | %s\n", $volume_usage, $volume_perf;
    exit $exit_code;
}

exit 255;
