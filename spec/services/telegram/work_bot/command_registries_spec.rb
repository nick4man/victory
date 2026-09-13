# frozen_string_literal: true

require 'rails_helper'

# BOTTLENECK — команда живёт в трёх реестрах: Router::COMMANDS (исполнение),
# telegram_bot_commands.yml (нативное «/»-меню) и Help::ENTRIES (/help).
# Промах в любом из них не ломает ничего заметного: команда просто не видна
# в меню или не упомянута в справке — и ей не пользуются.
#
# Раньше спека закрывала только пять команд воронки показов, «исторический дрейф
# по остальным — не её дело». Дрейф нашёлся ровно там, куда спека не смотрела:
# /unstage существовала как класс, была в Router и имела собственную спеку, но
# отсутствовала и в «/»-меню, и в /help — о ней просто никто не знал.
#
# Поэтому теперь инвариант, а не перечисление: новая команда не может тихо
# проскочить мимо меню, а новый алиас требует отдельной строки в WORKBOT_COMMAND_ALIASES ниже.
RSpec.describe 'реестры команд WorkBot' do
  # Алиасы намеренно живут только в Router: дублировать их в «/»-меню значит
  # засорять список синонимами, а лимит TG — 100 команд на scope.
  # Каждый алиас обязан указывать на тот же класс, что и основная команда.
  WORKBOT_COMMAND_ALIASES = {
    '/panel' => '/dashboard',
    '/shortcuts' => '/cheatsheet',
    '/start' => '/help'
  }.freeze

  # /start — особый случай: он и алиас (тот же класс, что /help), и обязан быть
  # в «/»-меню, потому что это первая кнопка, которую Telegram показывает новому
  # собеседнику бота. Поэтому в списке «только в Router» его нет.
  WORKBOT_ROUTER_ONLY_ALIASES = %w[/panel /shortcuts].freeze

  let(:router_cmds) { Telegram::WorkBot::Router::COMMANDS.keys.map(&:to_s) }

  let(:yaml_entries) do
    YAML.load_file(Rails.root.join('config/telegram_bot_commands.yml')).fetch('commands')
  end
  let(:yaml_cmds) { yaml_entries.map { |c| "/#{c.fetch('cmd')}" } }

  # В ENTRIES есть строки, которые командами не являются («🎙 Voice DM» —
  # подсказка про голосовые). Берём только те, что начинаются со слэша.
  let(:help_cmds) do
    Telegram::WorkBot::Commands::Help::ENTRIES
      .map { |cmd, _, _| cmd.to_s }
      .select { |cmd| cmd.start_with?('/') }
  end

  describe 'согласованность трёх реестров' do
    it 'каждая исполняемая команда (кроме алиасов) есть в «/»-меню' do
      missing = router_cmds - yaml_cmds - WORKBOT_ROUTER_ONLY_ALIASES
      expect(missing).to be_empty,
                         "не попали в config/telegram_bot_commands.yml: #{missing.join(', ')}"
    end

    it 'каждая исполняемая команда (кроме алиасов) описана в /help' do
      missing = router_cmds - help_cmds - WORKBOT_ROUTER_ONLY_ALIASES
      expect(missing).to be_empty,
                         "не попали в Help::ENTRIES: #{missing.join(', ')}"
    end

    it 'в «/»-меню нет команд, которых Router не умеет исполнять' do
      orphans = yaml_cmds - router_cmds
      expect(orphans).to be_empty,
                         "меню обещает то, чего нет в Router::COMMANDS: #{orphans.join(', ')}"
    end

    it 'в /help нет команд, которых Router не умеет исполнять' do
      orphans = help_cmds - router_cmds
      expect(orphans).to be_empty,
                         "справка обещает то, чего нет в Router::COMMANDS: #{orphans.join(', ')}"
    end
  end

  describe 'алиасы' do
    WORKBOT_COMMAND_ALIASES.each do |alias_cmd, canonical|
      it "#{alias_cmd} исполняется тем же классом, что и #{canonical}" do
        cmds = Telegram::WorkBot::Router::COMMANDS
        expect(cmds[alias_cmd]).to eq(cmds[canonical])
      end
    end

    it 'каждая команда, которой нет в меню, объявлена алиасом явно' do
      undeclared = router_cmds - yaml_cmds - WORKBOT_COMMAND_ALIASES.keys
      expect(undeclared).to be_empty,
                            'команда не в меню и не объявлена алиасом: ' \
                            "#{undeclared.join(', ')}. Либо добавь в YAML + Help, либо в ALIASES."
    end
  end

  describe 'формат «/»-меню' do
    it 'нет дублей — setMyCommands падает на повторах' do
      expect(yaml_cmds).to eq(yaml_cmds.uniq)
    end

    it 'укладывается в лимит Telegram (100 команд на scope)' do
      expect(yaml_cmds.size).to be <= 100
    end

    # TG валидирует имя команды на своей стороне: a-z, 0-9, _, 1-32 символа.
    # Одно нарушение роняет весь setMyCommands, а не одну строку.
    it 'имена команд проходят валидацию Telegram' do
      invalid = yaml_entries.map { |c| c.fetch('cmd') }.grep_v(/\A[a-z0-9_]{1,32}\z/)
      expect(invalid).to be_empty, "TG отвергнет: #{invalid.join(', ')}"
    end

    it 'каждая строка меню имеет tier, group и непустое описание' do
      broken = yaml_entries.reject do |c|
        %w[public staff manager director].include?(c['tier']) &&
          [true, false].include?(c['group']) &&
          c['desc'].to_s.strip.length.between?(1, 256)
      end
      expect(broken.map { |c| c['cmd'] }).to be_empty
    end
  end
end
