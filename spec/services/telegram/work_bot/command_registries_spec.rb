# frozen_string_literal: true

require 'rails_helper'

# BOTTLENECK — команда живёт в трёх реестрах: Router::COMMANDS (исполнение),
# telegram_bot_commands.yml (нативное «/»-меню) и Help::ENTRIES (/help).
# Промах в любом из них не ломает ничего заметного: команда просто не видна
# в меню или не упомянута в справке — и ей не пользуются. Спека закрывает
# только команды воронки показов: исторический дрейф по остальным не её дело.
#
RSpec.describe 'реестры команд show-воронки' do
  SHOW_COMMANDS = %w[segment show stage objections bargain].freeze

  let(:yaml_cmds) do
    YAML.load_file(Rails.root.join('config/telegram_bot_commands.yml'))
        .fetch('commands').map { |c| c.fetch('cmd') }
  end
  let(:help_cmds) do
    Telegram::WorkBot::Commands::Help::ENTRIES.map { |cmd, _, _| cmd.to_s.delete_prefix('/') }
  end
  let(:router_cmds) do
    Telegram::WorkBot::Router::COMMANDS.keys.map { |k| k.to_s.delete_prefix('/') }
  end

  SHOW_COMMANDS.each do |cmd|
    it "/#{cmd} зарегистрирована во всех трёх реестрах" do
      expect(router_cmds).to include(cmd)
      expect(yaml_cmds).to include(cmd)
      expect(help_cmds).to include(cmd)
    end
  end

  it 'в YAML нет дублей — setMyCommands падает на повторах' do
    expect(yaml_cmds).to eq(yaml_cmds.uniq)
  end
end
