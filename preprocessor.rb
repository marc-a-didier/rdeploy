
class PreProcessor

    def initialize(conf, target, opts)
        @conf = conf
        @target = target
        @processed = {}
        @stages = []

        @consts = {}
        opts.each { |k, v| @consts[k.to_s] = v }
    end

    def conditions_match?(block)
        return false if block['disabled']
        %w[packaging distro type].each do |block_type|
            if block[block_type]
                return false unless block[block_type].include?(@target[block_type])
            end
        end
        return true
    end

    def sub_consts(obj)
        obj.each { |k, v| self.sub_consts(v) } if obj.is_a?(Hash)
        obj.each { |e| self.sub_consts(e) } if obj.is_a?(Array)
        obj.scan(/__(\w+)__/).each do |m|
            obj.sub!("__#{m[0]}__", @consts[m[0]])
        end if obj.is_a?(String)
        obj.scan(/__\{(\w+)\}__/).each do |m|
            obj.sub!("__\{#{m[0]}\}__", @target[m[0]])
        end if obj.is_a?(String)
        return obj
    end

    def add_consts(pb)
        pb.select { |stage| stage['consts'] }.each do |stage|
            stage['consts'].each do |k, v|
                if k.match?(/packaging|location/)
                    v[@target[k]].each { |k2, v2| @consts[k2] = v2 }
                else
                    @consts[k] = v
                end
            end
        end

        # Fun... must call substitution on itself if consts are used inside consts block...
        sub_consts(@consts)

        pb.delete_if { |stage| stage['consts'] }
    end

    def process_depends(block)
        block['playbooks'].each { |playbook| self.process(playbook) } if conditions_match?(block)
    end

    def process(playbook)
        return if @processed[playbook]

        puts("Pre-processing play book #{playbook.green}".bold)

        # Mark current playbook as pre-processed
        @processed[playbook] = true

        pb = ConfigLoader.load(playbook+'.yml', [:sub_env_vars])

        # Check restriction on whole playbook if any
        pb.each do |stage|
            if stage['restrict'] && !conditions_match?(stage['restrict'])
                puts("Playbook #{playbook.red}".bold+" rejected due to restrictions.".bold)
                return
            end
        end
        pb.delete_if { |stage| stage['restrict'] }

        # Add defined consts in globals
        add_consts(pb)

        pb.each do |stage|
            stage.each do |type, block|
                if type == 'depends'
                    process_depends(block)
                else
                    process_depends(block['depends']) if block['depends']
                    sub_consts(block)
                    if conditions_match?(block)
                        # Remove now useless conditions from hash
                        block.delete_if { |k, v| k.match?(/disabled|depends|distro|packaging|type/) }
                        @stages << stage
                    end
                end
            end
        end
    end

    def analyze
        add_consts([{'consts' => @conf['consts']}])
        sub_consts(@conf)

        @conf['playbooks'].each { |pb| self.process(pb['name']) }

        return @stages
    end
end
