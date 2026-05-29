# frozen_string_literal: true

namespace :topnlab_docs do
  desc 'Index .claude/docs/topnlab/*.md into TopnlabDocChunk (chunk by H2, embed via Gemini)'
  task index: :environment do
    stats = TopnlabDocs::Indexer.new.call
    puts ''
    puts 'Topnlab docs indexing summary:'
    stats.each do |file, counts|
      puts "  #{file}: #{counts.inspect}"
    end
    total = TopnlabDocChunk.count
    puts ''
    puts "Total chunks in DB: #{total}"
  end

  desc 'Semantic search over Topnlab docs. Usage: rake "topnlab_docs:search[как получить МЛС]"'
  task :search, [:query] => :environment do |_t, args|
    query = args[:query].to_s.strip
    if query.empty?
      abort 'Usage: bin/rails "topnlab_docs:search[<query>]"'
    end

    results = TopnlabDocs::Searcher.new(query).call

    if results.empty?
      puts "No results. Did you run `bin/rails topnlab_docs:index` first?"
      exit 0
    end

    puts ''
    puts "Top #{results.size} results for: #{query.inspect}"
    puts '─' * 80
    results.each_with_index do |r, i|
      puts ''
      puts "#{i + 1}. #{r[:file]} (line #{r[:line] || '?'}) [sim=#{r[:similarity]}]"
      puts "   #{r[:section]}" if r[:section].present?
      puts '   ' + r[:text].lines.first(3).join.strip.truncate(220).gsub(/\n+/, ' / ')
    end
    puts ''
    puts '─' * 80
    puts "Read full sections via:"
    puts "  Read .claude/docs/topnlab/<file>  with offset=<line>"
  end
end
