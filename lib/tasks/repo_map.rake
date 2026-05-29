# frozen_string_literal: true

namespace :repo do
  desc 'Regenerate .claude/repo-map.md (full signature dump) + .claude/repo-index.md (compact class list) for AI assistants'
  task :map do
    root = Rails.root
    map_path = root.join('.claude/repo-map.md').to_s
    index_path = root.join('.claude/repo-index.md').to_s

    # 1) Full signature map via repomix (compressed + comments stripped)
    cmd = [
      'npx', '-y', 'repomix',
      '--compress',
      '--remove-comments',
      '--remove-empty-lines',
      '--output', map_path,
      '--include',
      'app/models/**,app/controllers/**,app/services/**,app/jobs/**,app/mailers/**,app/channels/**,config/routes.rb,db/schema.rb,Gemfile'
    ]
    puts "Running: #{cmd.join(' ')}"
    abort 'repo:map (repomix) failed' unless system(*cmd, chdir: root.to_s)

    # 2) Compact class index — one line per .rb file, ~5k tokens total
    File.open(index_path, 'w') do |f|
      f.puts '# repo-index.md — карта классов (auto-generated)'
      f.puts
      f.puts '> Сжатый индекс: путь → классы/модули в файле. Регенерация: `rake repo:map`.'

      %w[app/models app/controllers app/services app/jobs app/mailers app/channels lib].each do |dir|
        path = root.join(dir)
        next unless path.directory?

        f.puts
        f.puts "## #{dir}"
        f.puts
        f.puts '```'
        Dir.glob(path.join('**/*.rb')).sort.each do |file|
          classes = File.foreach(file)
                        .select { |l| l =~ /^\s*(class|module)\s+[A-Z]/ }
                        .map { |l| l.strip.sub(/\s*<.*$/, '') }
                        .join(', ')
          rel = Pathname.new(file).relative_path_from(root)
          f.puts "#{rel} — #{classes}" unless classes.empty?
        end
        f.puts '```'
      end
    end

    map_kb = (File.size(map_path).to_f / 1024).round(1)
    index_kb = (File.size(index_path).to_f / 1024).round(1)
    puts "OK: #{map_path} (#{map_kb} KB) + #{index_path} (#{index_kb} KB)"
  end
end
