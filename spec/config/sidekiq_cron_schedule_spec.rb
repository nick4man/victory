# frozen_string_literal: true

require 'rails_helper'
require 'fugit'

# Расписание едет вместе с кодом, а проверить его до сих пор было нечем:
# sidekiq-cron при нерезолвящемся классе пишет строку в лог и идёт дальше,
# а джоба, которой нужны аргументы, падает уже на первом тике в проде.
# Обе поломки тихие — ровно тем и опасны.
#
# Контекст: шесть задач числились «запланированными», живя только в
# config/schedule.rb, который без гема `whenever` никогда не исполнялся.
RSpec.describe 'config/sidekiq_cron.yml' do
  subject(:schedule) do
    YAML.safe_load(ERB.new(Rails.root.join('config/sidekiq_cron.yml').read).result, aliases: true)
  end

  it 'парсится в непустой hash' do
    expect(schedule).to be_a(Hash)
    expect(schedule).to be_present
  end

  it 'каждая запись объявляет class, cron и queue' do
    schedule.each do |name, entry|
      expect(entry).to include('class', 'cron', 'queue'), "#{name}: не хватает обязательных ключей"
    end
  end

  it 'каждый class резолвится в существующую константу' do
    schedule.each do |name, entry|
      expect { entry['class'].constantize }
        .not_to raise_error, "#{name}: класс #{entry['class']} не существует"
    end
  end

  it 'каждый cron-expression разбирается fugit' do
    schedule.each do |name, entry|
      expect(Fugit.parse_cron(entry['cron'])).to be_present,
                                                 "#{name}: cron #{entry['cron'].inspect} не парсится"
    end
  end

  # Периодическая задача вызывается без аргументов. Джоба с обязательным
  # параметром (PropertyValuationFollowUpJob(valuation_id), например) в
  # расписании работать не может — ловим это здесь, а не в проде.
  it 'ни одна запланированная джоба не требует аргументов' do
    schedule.each do |name, entry|
      # filter_map, а не select: Style/HashSlice принимает `parameters` за Hash
      # и предлагает `slice(:req, :keyreq)`, а это Array пар — slice на нём
      # означает срез по индексу. Заодно сразу получаем имена для сообщения.
      required = entry['class'].constantize.instance_method(:perform).parameters
                               .filter_map { |type, arg| arg if %i[req keyreq].include?(type) }

      expect(required).to be_empty,
                          "#{name}: #{entry['class']}#perform требует #{required.join(', ')}"
    end
  end

  it 'очереди обслуживаются воркером из config/sidekiq.yml' do
    raw = ERB.new(Rails.root.join('config/sidekiq.yml').read).result
    known = YAML.safe_load(raw, permitted_classes: [Symbol], aliases: true)
                .fetch(:queues, []).map { |q| q.is_a?(Array) ? q.first : q }

    schedule.each do |name, entry|
      expect(known).to include(entry['queue']), "#{name}: очередь #{entry['queue']} не обслуживается"
    end
  end
end
