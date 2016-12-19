#!/usr/bin/env ruby

require 'pty'
require 'json'
require 'optparse'

$options = {}
parser = OptionParser.new
parser.banner = "Usage: farm-command.rb [options] -e 'commands;to;run' -t 'target,hosts'"

parser.on('-h', '--help', 'Prints this help') do |h|
    puts parser
    exit 1
end

parser.on('-eCOMMAND', '--commands=COMMAND', String, 'Command(s) to execute on the hosts') do |e|
    $options[:command] = e
end

parser.on('-tHOSTS', '--targets=HOSTS', String, 'Target hosts to connect to. Can be file, one host per line') do |t|
    $options[:targets] = t
end

parser.on('-mMAX', '--max=MAX', Integer, 'Max concurrent connections (Default: 1)') do |m|
    $options[:max] = m
end

parser.on('-d', '--debug', 'Print debug messages') do |d|
    $options[:debug] = d
end
parser.parse!

if $options.keys.size == 0
    puts parser
    exit 1
end

if not $options[:command]
    raise 'Failed to provide command(s) to execute'
end

if not $options[:targets]
    raise 'Failed to provide target hosts'
end

max_jobs = $options[:max] || 1
$jobs = (1..max_jobs).to_a.map{|x| [x, {:pid => 0}]}.to_h

hosts = []
if File.exists?($options[:targets])
    File.open($options[:targets], 'r') do |fh|
        while line = fh.gets
            hosts.push(line.chomp)
        end
    end
else
    hosts = $options[:targets].split(',')
end

def run_command(command, input)
    if $options[:debug]
        $stderr.puts "DEBUG Running command '#{command}'"
        if input != ''
            $stderr.puts "DEBUG   With an input '#{input}'"
        end
    end

    master, slave = PTY.open
    pread, pwrite = IO.pipe
    pid = spawn(command, :in => pread, :out => slave, :err => slave)

    pread.close
    slave.close

    if input != ''
        pwrite.puts(input)
    end
    pwrite.close

    out = ''
    begin
        master.each do |line|
            out.concat(line)
        end
    rescue Errno::EIO
    end

    master.close
    Process.wait(pid)

    return out, $?.exitstatus
end

def ssh_command(host, command)
    ssh_opts = [
        '-q',
        '-o ConnectTimeout=10',
        '-o StrictHostKeyChecking=no',
        '-o PasswordAuthentication=no',
    ]

    shell = '/bin/bash --noprofile --norc --login'

    ssh_comm = "ssh #{ssh_opts.join(' ')} #{host} #{shell}"
    return run_command(ssh_comm, command)
end

def print_log(log)
    puts log.readline
    log.close
end

def set_job(job, args = {})
    $jobs[job] = args
end

def reset_job(pid)
    $jobs.keys.each do |job|
        if $jobs[job][:pid] == pid
            $jobs[job][:pid] = 0
            print_log($jobs[job][:log])
        end
    end
end

$done = false
while true
    begin
        while (pid = Process.waitpid(-1, Process::WNOHANG)) != nil
            reset_job(pid)
            break
        end
    rescue Errno::ECHILD
    end

    active = $jobs.select{|key, val| val[:pid] != 0}
    if active.keys.size == max_jobs
        if $options[:debug]
            $stderr.puts('DEBUG all workers consumed, sleeping')
        end

        sleep 1
        next
    elsif active.keys.size == 0 and $done == true
        if $options[:debug]
            $stderr.puts('DEBUG all jobs done, pids reaped. Breaking out of main loop')
        end

        break
    elsif active.keys.size == 0 and hosts.size == 0 and $done == false
        if $options[:debug]
            $stderr.puts('DEBUG all jobs done, hosts emptied, marking done')
        end

        $done = true
        next
    elsif hosts.size == 0 and $done == false
        next
    elsif active.keys.size < max_jobs and
      job = $jobs.select{|key, val| val[:pid] == 0}.keys.shift and
      host = hosts.shift
        if $options[:debug]
            $stderr.puts("DEBUG got a new job to work on '#{host}'")
        end

        log_reader, log_writer = IO.pipe
        pid = fork
        if pid == nil
            log_reader.close
            start = Time.now.to_f
            output, status = ssh_command(host, $options[:command])
            log_writer.puts(JSON.generate({
                :host  => host,
                :mesg  => output,
                :exit  => status,
                :start => start,
                :end   => Time.now.to_f
            }))
            log_writer.close
            exit
        else
            set_job(job, {:pid => pid, :log => log_reader})
        end
    end
end

