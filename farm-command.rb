#!/usr/bin/env ruby

require 'pty'
require 'json'

# need to read up on getops parsing, statically define max concurrent connections
max_jobs = 3
# setup default structure for jobs
$jobs = (1..max_jobs).to_a.map{|x| [x, {:pid => 0}]}.to_h

# need to read up on getops parsing, statically define the target hosts here
#hosts = ['go', 'perl', 'go', 'perl', 'go', 'perl', 'go']
hosts = ['go']

# define how to execute a command with control over streams
def run_command(command, input)
    master, slave = PTY.open
    pread, pwrite = IO.pipe
    pid = spawn(command, :in => pread, :out => slave, :err => slave)

    pread.close
    slave.close

    pwrite.puts(input)
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

# command wrapper to execute ssh connections
# this needs to be fancied up
def ssh_command(host, command)
    ssh = "ssh #{host} /bin/bash --noprofile --norc --login"
    return run_command(ssh, command)
end

# job management
def set_job(job, args = {})
    $jobs[job] = args
end

def reset_job(pid)
    $jobs.keys.each do |job|
        if $jobs[job][:pid] == pid
            $jobs[job][:pid]   = 0
            $jobs[job][:host]  = ""
            $jobs[job][:start] = 0
            # make a function to record the log messages
            puts $jobs[job][:log].readline
            $jobs[job][:log].close
        end
    end
end

# process the hosts
$done = false
while true
    # reap children
    begin
        while (pid = Process.waitpid(-1, Process::WNOHANG)) != nil
            reset_job(pid)
            break
        end
    rescue Errno::ECHILD
    end

    # find our active jobs
    active = $jobs.select{|key, val| val[:pid] != 0}
    # sleep if we are busy
    if active.keys.size == max_jobs
        sleep 1
        next
    # break if we are done
    elsif active.keys.size == 0 and $done == true
        break
    # indicate we have completed all hosts and workers are finished
    elsif active.keys.size == 0 and hosts.size == 0 and $done == false
        $done = true
        next
    # do nothing if hosts are consumed
    elsif hosts.size == 0 and $done == false
        sleep 1
        next
    # fork off a job to work on the host
    elsif active.keys.size < max_jobs and
      job = $jobs.select{|key, val| val[:pid] == 0}.keys.shift and
      host = hosts.shift
        log_reader, log_writer = IO.pipe
        pid = fork
        if pid == nil
            log_reader.close
            output, status = ssh_command(host, ARGV.join(' '))
            log_writer.puts(JSON.generate({:host => host, :mesg => output, :exit => status}))
            log_writer.close
            exit
        else
            set_job(job, {
                :pid => pid,
                :host => host,
                :start => Time.now.to_i,
                :log => log_reader
            })
        end
    end
end

