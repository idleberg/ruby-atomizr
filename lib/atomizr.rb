require "json"
require "nokogiri"
require "fileutils"

class Atomizr

    @name = Gem.loaded_specs["atomizr"].name.capitalize
    @version = Gem.loaded_specs["atomizr"].version
    @author = Gem.loaded_specs["atomizr"].authors
    @homepage = Gem.loaded_specs["atomizr"].homepage

    # Arrays of filters to replace characters in strings
    @filename_filter =  [
        [/[\x00\/\\:\*\?\"\$<>\|]/, '_'],
        ["\t",  "-"]
    ]
    @title_filter = [
        [/\x27/, "\\\\'"],  # single-quote
        [/\x22/, "\\\""],   # double-quote
        [/\x5C/, "\\\\"],   # backslash
    ]
    @prefix_filter = [
        [/[\x00\x22\x27\/\\:\*\?\"\'\$<>\{\}\|]/, '']
    ]
    @body_filter = [
        [/\x27/, "\\\\'"],  # single-quote
        [/\x22/, "\\\""],   # double-quote
        [/\x5C/, "\\\\"],   # backslash
    ]
    @scope_filter = [ 
        # https://gist.github.com/idleberg/fca633438329cc5ae317
        [',', ''],
        [/\.?source\.c\+\+/, '.source.cpp'],
        [/\.?source\.java-props/, '.source.java-properties'],
        [/\.?source\.objc\+\+/, '.source.objcpp'],
        [/\.?source\.php/, '.text.html.php'],
        [/\.?source\.scss/, '.source.css.scss'],
        [/\.?source\.todo/, '.text.todo'],
        [/\.?text\.html\.markdown/, '.source.gfm']
    ]

    def self.info
        puts "\n#{@name}, version #{@version}\nThe MIT License\nCopyright (c) 2015, 2016 #{@author.join(", ")}"
    end

    def self.version
        puts "#{@version}"
    end

    def self.read_file(input, type)
        if $merge == true
            init_hashes()
        end

        Dir.glob(input) do |item|

            if $merge == false
                init_hashes()
            end

            @data = send("read_#{type}", item)

            if $merge == false
                write_data(item)
            end
        end

        if $merge == true
            write_data($output)
        end
    end


    def self.read_xml(item)

        puts "\nReading snippet file '#{item}'" unless $silent == true

        # read file, parse data
        file = File.read(item)

        # validate file
        if (valid_xml?(file) == false) && ($no_validation == false)
            abort("\nError: Invalid XML file '#{item}'") unless $silent == true 
        end

        data = Nokogiri::XML(file)

        if (item.end_with? ".tmSnippet") || ($is_tm == true)
            @data['completions'] = read_textmate_xml(item, data)
        else
            @data['completions'] = read_sublime_xml(item, data)
        end

        $input_counter += 1

        return @data
    end

    def self.read_sublime_xml(item, data)

        # get scope
        @data['scope'] = get_scope( data.xpath("//scope")[0].text.strip )

        trigger = data.xpath("//tabTrigger")[0].text.strip
        
        if data.xpath("//description").empty?
            description = trigger
        else
            description = data.xpath("//description")[0].text.strip
        end

        data.xpath("//content").each do |node|

            title  = filter_str(trigger, @title_filter)
            prefix = filter_str(trigger, @prefix_filter)
            body   = filter_str(node.text.strip, @body_filter)

            if @completions.has_key?(title)
                if $dupes == false
                    puts " !! Duplicate trigger #{title.dump} in #{item}" unless $silent == true
                else
                    abort("\nError: duplicate trigger '#{title.dump}' in #{item}. Triggers must be unique.")
                end
            end

            @completions[description] = {
                :prefix => prefix,
                :body => body
            }
        end

        return @completions
    end

    def self.read_textmate_xml(item, data)

        data.xpath('//dict').each do | node |
          node.element_children.map(&:content).each_slice(2) do | k, v |
            case k
            when 'scope'
                @data['scope'] = get_scope(v.to_s)
            when 'name'
                @title = filter_str(v.to_s, @title_filter)
            when 'tabTrigger'
                @prefix = filter_str(v.to_s, @prefix_filter)
            when 'content'
                @body = filter_str(v.to_s.strip, @body_filter)
            else
                next
            end
          end
        end

        @completions[@title] = {
            :prefix => @prefix,
            :body => @body
        }

        return @completions
    end

    def self.read_json(item)

        puts "\nReading completion file '#{item}'" unless $silent == true

        # read file
        file = File.read(item)

        # validate file
        if (valid_json?(file) == false) && $no_validation == false
            abort("\nError: Invalid JSON file '#{item}'") unless $silent == true 
        else
            data = JSON.load(file)
        end

        # get scope
        @data['scope'] = get_scope( data["scope"] )

        data["completions"].each do |line|
            trigger = line["trigger"]

            # Next if JSON contains non-standard keys
            if trigger == nil
                puts " >> Ignoring line #{line}" unless $silent == true
                next
            end 

            contents = line["contents"]

            title  = filter_str(trigger, @title_filter)
            prefix = filter_str(trigger, @prefix_filter)
            body   = filter_str(contents, @body_filter)

            if @completions.has_key?(title)
                if $dupes == false
                    puts " !! Duplicate trigger #{title.dump} in #{item}" unless $silent == true
                else
                    abort("\nError: duplicate trigger '#{title.dump}' in #{item}. Triggers must be unique.") unless $silent == true 
                end
            end

            @completions[title] = {
                :prefix => prefix,
                :body => body
            }
        end

         @data['completions'] = @completions

        $input_counter += 1
        return @data
    end

    # via https://gist.github.com/ascendbruce/7070951
    def self.valid_json?(json)
        JSON.parse(json)
        true
    rescue
        false
    end

    def self.valid_xml?(xml)
        Nokogiri::XML(xml) { |config| config.options = Nokogiri::XML::ParseOptions::STRICT }
        true
    rescue
        false
    end

    def self.write_data(item)
        if $output == "json"
            file = get_outname('json', item)
            write_json(@data, file, $split)
        else
            file = get_outname('cson', item)
            write_cson(@data, file, $split)
        end
    end

    def self.write_json(data, file, many = false)

        if many == false

            if $no_comment == true
                json = {
                    data['scope'] => data['completions']
                }
            else
                json = {
                    :"#" => "# Generated with #{@name} - #{@homepage}",
                    data['scope'] => data['completions']
                }
            end

            puts "Writing '#{file}'" unless $silent == true
            File.open("#{$folder}/#{file}","w") do |f|
              f.write(JSON.pretty_generate(json))
            end
            $output_counter += 1

        elsif many == true

            scope = data['scope']

            data['completions'].each do |item|

                file = filter_str(item[1][:prefix], @filename_filter)

                json = {
                    data['scope'] => {
                        item[0] => {
                            'prefix' => item[1][:prefix],
                            'body' => item[1][:body]
                        }
                    }
                }

                puts "Writing '#{file}.json'" unless $silent == true
                File.open("#{$folder}/#{file}.json","w") do |f|
                  f.write(JSON.pretty_generate(json))
                end
                $output_counter += 1
            end
        end
    end

    def self.write_cson(data, item, many = false)

        if many == false

            if $no_comment == true
                comment = ""
            else
                comment =  "# Generated with #{@name} - #{@homepage}\n"
            end

            cson = comment
            cson += "'"+data['scope']+"':\n"

            data['completions'].each do |item|

                title = item[0]
                prefix = item[1][:prefix]
                body = item[1][:body]

                if $no_tabstops == false
                    body = add_trailing_tabstop(body)
                end

                cson += "  '"+title+"':\n"
                cson += "    'prefix': '"+prefix+"'\n"
                if body.lines.count <= 1
                    cson += "    'body': '"+body+"'\n"
                else
                    cson += "    'body': \"\"\"\n"
                    body.each_line do |line|
                        cson += "      "+line
                    end
                    cson +="\n    \"\"\"\n"
                end
            end

            if File.directory?($input[0])
                mkdir("#{$folder}/#{$output}/snippets")
                file = $output + '/snippets/' + item + '.cson'
            else
                file = get_outname('cson', item)
            end

            puts "Writing '#{file}'" unless $silent == true
            File.open("#{$folder}/#{file}","w") do |f|
              f.write(cson)
            end
            $output_counter += 1

        elsif many == true

            scope = data['scope']

            data['completions'].each do |item|

                cson = "'"+scope+"':\n"
                title = item[0]
                prefix = item[1][:prefix]
                body = item[1][:body]

                file = filter_str(prefix, @filename_filter)

                cson += "  '"+title+"':\n"
                cson += "    'prefix': '"+prefix+"'\n"
                if body.lines.count <= 1
                    cson += "    'body': '"+body+"'\n"
                else
                    cson += "    'body': \"\"\"\n"
                    body.each_line do |line|
                        cson += "      "+line
                    end
                    cson +="\n    \"\"\"\n"
                end

                puts "Writing '#{file}.cson'" unless $silent == true
                File.open("#{$folder}/#{file}.cson","w") do |f|
                  f.write(cson)
                end
                $output_counter += 1
            end
        end
    end

    def self.delete_file(input)

        if File.directory?(input)
            puts "\nDeleting '#{input[0..-2]}'" unless $silent == true
            FileUtils.rm_rf(input)
        else
            Dir.glob(input) do |item|
                puts "Deleting '#{item}'" unless $silent == true
                File.delete(item)
            end
        end

    end

    def self.get_outname(type, item)
        if $output == type

            if $input[0].include?("*")
                file = item
            else
                file = $input[0]
            end
            output = File.basename(file, ".*")+"."+type
        else
            output = $output
        end

        return output
    end

    def self.get_scope(scope)

        if $scope == nil
            scope = fix_scope(filter_str(scope, @scope_filter))
            puts "Using default scope '"+scope+"'" unless $silent == true
        else
            scope = fix_scope(filter_str($scope, @scope_filter))
            puts "Override scope using '"+scope+"'" unless $silent == true
        end

        return scope
    end

    def self.add_trailing_tabstop(input)
        unless input.match(/\$\d+$/) == nil
            # nothing to do here
            return input
        end

        return "#{input}$0"
    end

    # prepend dot to scope
    def self.fix_scope(scope)
        if scope[0] != "."
            scope = "."+ scope
        end

        return scope
    end

    def self.filter_str(input, filter)

        if filter.any?
            filter.each do |needle, replacement|
                input = input.to_s.gsub(needle, replacement)
            end
        end

        return input
    end

    def self.init_hashes()
        @data = Hash.new
        @completions = Hash.new
    end

    def self.mkdir(folder)
      if !Dir.exists?(folder)
        FileUtils.mkdir_p(folder)
      end
    end

    def self.copy_file(src, dest, del = false)
      File.write(dest, File.read(src))

      if del == true
        File.delete(src)
        end
    end

end