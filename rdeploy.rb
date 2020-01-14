#!/usr/bin/env ruby

require 'psych'
require 'json'
require 'logger'

require 'net/ssh'
require 'net/scp'
require 'rblibs/utils'
require 'rblibs/configloader'
require 'rblibs/cmdparser'
require 'rblibs/ssh_utils'

require './preprocessor'

class RDeploy

    REMOTE_TMP_DIR = '/tmp/rdeploy'

    def initialize(conf, target, host, opts)
        @conf   = conf
        @target = target.transform_values { |v| v.dup } # Clone target cause we're multithreading
        @opts   = opts

        # Add actual default values to target if not present
        @target.merge!(@conf['target']) { |key, curr_val, def_val| curr_val }

        @logger = Logger.new(File.open("./logs/rdeploy_#{host}.log", 'w')) unless @opts[:dry_run]
        @logger.info("Starting deployment on #{@target['type']}, host #{host}") unless @opts[:dry_run]

        # Command logging
        @replay_file = "./logs/last_run_state_#{host}.json"
        @jsonlog = {}
        @prevlog = @opts[:replay] && File.exists?(@replay_file) ? JSON.parse(IO.read(@replay_file)) : {}
        @cmdid   = 0

        @target['host'] = host.split(':').first
        @target['port'] = host.split(':').last.to_i if host.match?(/.+:/)

        # SSH connection to target
        @ssh = nil
    end

    def container?
        return @target['type'] != 'ssh'
    end

    def packaging
        return @conf['packaging'][@target['packaging']]
    end

    def prepare_and_exec(cmd, &block)
        @cmdid += 1
        res = ['', 0] # 0 if dry run or replay and was 0

        if @opts[:replay] && @prevlog[@cmdid.to_s] && @prevlog[@cmdid.to_s]['status'] == 0 && @prevlog[@cmdid.to_s]['cmd'] == cmd
            puts("Skipping already sucessful cmd #{cmd}")
        else
            puts("Executing command #{cmd.green}".bold)
            res = yield(block) unless @opts[:dry_run]
        end

        @jsonlog[@cmdid] = { 'cmd' => cmd, 'status' => res.last }
        IO.write(@replay_file, JSON.pretty_generate(@jsonlog)) if @opts[:secure]

        return res
    end

    def local_exec(cmd)
        @logger.info("Executing local command: #{cmd}") if @logger
        out = `#{cmd}`
        @logger.info("Command exit code: #{$?.exitstatus}") if @logger
        [out, $?.exitstatus]
    end

    # mode==:force -> re-execute the command even if it was successful, mainly due to clean up
    def remote_exec(cmd, mode = :std)
        cmd = "docker exec --user #{@target['user']} #{@target['host']} sh -c '"+cmd.gsub("'", "\\\\'")+"\'" if container?
        return prepare_and_exec(cmd) { container? ? local_exec(cmd) : @ssh.ssh_exec(cmd, @logger) }
    end

    def show_meter(percentage)
        ml = percentage*72/100
        print("\r"+'['.gray.bold+('='*ml).green.bold+' '*(72-ml)+"] #{percentage}%".gray.bold)
    end

    def ssh_upload(src, dest, type, options = {})
        cmd = (container? ? 'docker cp -L ' : 'scp ')+src+' '+(container? ? @target['host']+':' : '')+dest
        return prepare_and_exec(cmd) do
            if container?
                local_exec(cmd)
            else
                @ssh.scp.upload!(src, dest, options) do |ch, name, sent, total|
                    puts("Copying resource #{name} to #{dest}") if sent == 0 && type == :dir
                    show_meter(sent*100/total)
                    puts if sent == total
                end
                puts
                ['', 0]
            end
        end
    end

    def process_install(block)
        # Execute packages installation in one shot
        remote_exec(packaging['install']+' '+block['packages'].join(' '))
    end

    def process_gems(block)
        block['list'].each { |gem| remote_exec(@conf['gems']+' '+gem) if remote_exec("gem list -i #{gem}").last != 0 }
    end

    def process_shell(block)
        block['commands'].each { |cmd| remote_exec(cmd) }
    end

    def process_local_shell(block)
        block['commands'].each { |cmd| prepare_and_exec(cmd) { local_exec(cmd) } }
    end

    def prepare_copy(block)
        # Copy source location to destination if not found
        block['dest'] = block['src'] unless block['dest']

        # Always copy to a temp location
        dest = REMOTE_TMP_DIR
        # Don't try to remove REMOTE_TMP_DIR/./
        unless block['dest'] == './'
            dest = File.join(dest, block['dest'])

            # Cleanup/Create temp location
            remote_exec("rm -rf #{dest}; mkdir -p #{dest}")
        end

        return dest
    end

    def finalize_copy(block, dest, res, type)
        # Copied resources are moved to the final destination on the remote machine

        if type == :dir
            # Remove destination dir if it exists
            remote_exec("sudo rm -rf #{File.join(block['dest'], res)}")
        else
            # Create destination dir for files to come
            remote_exec("sudo mkdir -p #{block['dest']}")
        end

        # Move from /tmp to true destination dir
        remote_exec("sudo mv -f #{File.join(dest, res)} #{File.join(block['dest'], res)}")

        @logger.info("Copied resource #{res} to #{block['dest']}") unless @opts[:dry_run]

        remote_exec("sudo chown -R #{block['owner']} #{File.join(block['dest'], res)}") if block['owner']
        remote_exec("sudo chmod -R #{block['mode']} #{File.join(block['dest'], res)}") if block['mode']
    end

    def process_resources(block)
        block['files'].each do |files|
            dest = prepare_copy(files)

            files['names'].each do |file|
                Dir[File.join(files['src'], file)].each do |src|
                    ssh_upload(src, dest, :file)
                    finalize_copy(files, dest, File.basename(src), :file)
                end
            end
        end if block['files']

        block['dirs'].each do |dirs|
            dest = prepare_copy(dirs)

            dirs['names'].each do |dir|
                ssh_upload(File.join(dirs['src'], dir), dest, :dir, :recursive => true)
                finalize_copy(dirs, dest, dir, :dir)
            end
        end if block['dirs']

        block['updates'].each do |update|
            # Add a \n to created file so it can be handled by sed
            remote_exec("sudo printf '\\n' > #{update['file']}") if update['create']

            update['sed'].each do |sed|
                cmd = "sudo sed -i '#{sed['pattern']}"
                cmd += ' '+sed['lines'].gsub(/\n/, '\n') if sed['lines']
                cmd += "' #{update['file']}"
                remote_exec(cmd)
            end if update['sed']

            @logger.info("Updated/Created resource #{update['file']}") unless @opts[:dry_run]

        end if block['updates']
    end

    def run
        stages = PreProcessor.new(@conf, @target, @opts).analyze

        @ssh = SSHUtils.connect_with_credentials(@target['host'], @target) unless @opts[:dry_run] || container?

        # Cleanup target temp repo for copies
        remote_exec("sudo rm -rf #{REMOTE_TMP_DIR}; mkdir #{REMOTE_TMP_DIR}")

        # Process target system update/upgrade once before processing playbooks
        remote_exec(packaging['update'])  if @target['update']
        remote_exec(packaging['upgrade']) if @target['upgrade']

        # Execute each stage
        stages.each do |stage|
            stage.each do |type, block|
                puts("Processing block #{type.green}".bold)

                puts(block.inspect, "\n") if @opts[:dry_run]
                self.send("process_#{type.sub(/-/, '_')}".to_sym, block)
            end
        end

        IO.write(@replay_file, JSON.pretty_generate(@jsonlog)) unless @opts[:secure]

        @ssh.close if @ssh
    end
end

module Runner

    OPTIONS = [
        CmdParser::Option.new(:pb, '--pb p', { :call_back => ->(v) { v.split(',') } }), # List of playbooks
        CmdParser::Option.new(:location, '--location p'),
        CmdParser::Option.new(:distro, '--distro p'),
        CmdParser::Option.new(:packaging, '--packaging p'),
        CmdParser::Option.new(:hosts, '--hosts p', { :call_back => ->(v) { v.split(',') } }),
        CmdParser::Option.new(:port, '--port p'),
        CmdParser::Option.new(:user, '--user p'),
        CmdParser::Option.new(:targets, '--targets p'), # Targets definition file
        CmdParser::Option.new(:target, '--target p'),   # Target to use from the targets definition file
        CmdParser::Option.new(:replay, '--replay'),     # Use json log to skip successful commands
        CmdParser::Option.new(:secure, '--secure'),     # Rewrite json log file at each command
        CmdParser::Option.new(:dry_run, '--dry-run')    # Debug mode, display commands but don't execute
    ]

    def self.dispatch
        conf = ConfigLoader.load(__FILE__.sub(/rb$/, 'yml'), [:sub_env_vars])

        opts = CmdParser.parse(OPTIONS)

        targets = ConfigLoader.load(opts[:targets] || conf['targets'], [:sub_env_vars])

        if opts[:pb]
            opts[:pb].each { |pb| conf['playbooks'] << { 'name' => pb, 'active' => true } }
            conf['playbooks'] = conf['playbooks'].select { |pb| pb['active'] }.uniq { |pb| pb['name'] }
        end

        (opts[:target] ? targets[opts[:target]] : targets[conf['default_target']]).map do |target|
            [:hosts, :port, :user, :location, :distro, :packaging, :type].each { |opt| target[opt.to_s] = opts[opt] if opts[opt] }
            target['hosts'].map { |host| Thread.new { RDeploy.new(conf, target, host, opts).run } }
        end.flatten.each(&:join)
    end

end

Runner.dispatch
