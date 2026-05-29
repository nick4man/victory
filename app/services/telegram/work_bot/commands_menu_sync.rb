# frozen_string_literal: true

require 'yaml'

module Telegram
  module WorkBot
    # Phase 14 Iter 58 — синхронизация native TG /-меню через setMyCommands.
    #
    # Каталог команд: `config/telegram_bot_commands.yml` (single source of truth).
    # Tiers: public / staff / manager / director (cumulative).
    # Group flag: показывать ли команду в `BotCommandScopeAllGroupChats`.
    #
    # Scopes которые мы устанавливаем:
    #   1. `default`            — public-tier (для незарегистрированных и общий fallback)
    #   2. `all_group_chats`    — pipeline subset (group: true в YAML)
    #   3. `chat`               — per-user (DM каждого зарегистрированного staff)
    #
    # Когда вызывается:
    #   • `sync_global!` — один раз при deploy через `rake bot:sync_commands`
    #   • `sync_for_user!(tg_user)` — реактивно из:
    #     - commands/start.rb       (после установки dm_chat_id)
    #     - commands/promote.rb     (после role mutation)
    #     - commands/demote.rb      (то же)
    #     - commands/link.rb        (то же)
    #     - commands/deactivate.rb  (очистить меню)
    #
    # Все вызовы — fire-and-forget с rescue в hooks: sync failure НЕ должна ломать
    # бизнес-логику команды.
    class CommandsMenuSync
      CONFIG_PATH = Rails.root.join('config/telegram_bot_commands.yml')
      LANGUAGE    = 'ru'

      def initialize(client: Telegram::Client.new)
        @client = client
      end

      # Global scopes — default (public) + all_group_chats (pipeline subset).
      # @return [Boolean] true при успехе
      def sync_global!
        @client.set_my_commands(
          commands: tg_format(tier_commands([:public])),
          scope: { type: 'default' },
          language_code: LANGUAGE
        )
        @client.set_my_commands(
          commands: tg_format(group_commands),
          scope: { type: 'all_group_chats' },
          language_code: LANGUAGE
        )
        true
      end

      # Per-user scope=chat — для конкретного TelegramUser.
      # Если status != 'active' → delete commands (TG fallback'нется на default).
      # Если dm_chat_id отсутствует → noop (юзер не делал /start, не можем DM'ить).
      #
      # @param tg_user [TelegramUser]
      # @return [Boolean] true если был сделан API-вызов; false если skip (no dm_chat_id)
      def sync_for_user!(tg_user)
        return false if tg_user.dm_chat_id.blank?

        scope = { type: 'chat', chat_id: tg_user.dm_chat_id }

        if tg_user.status == 'active'
          @client.set_my_commands(
            commands: tg_format(tier_commands(tiers_for(tg_user))),
            scope: scope,
            language_code: LANGUAGE
          )
        else
          @client.delete_my_commands(scope: scope, language_code: LANGUAGE)
        end
        true
      end

      # Возвращает массив tier'ов которые видны данному пользователю (cumulative).
      # Public экспонировано для тестирования и для возможного использования в /help.
      def tiers_for(tg_user)
        if tg_user.can_voice_distribute?
          %i[public staff manager director]
        elsif tg_user.manager_or_director?
          %i[public staff manager]
        else
          %i[public staff]
        end
      end

      private

      def catalog
        @catalog ||= YAML.safe_load_file(CONFIG_PATH, symbolize_names: true)[:commands]
      end

      def tier_commands(tiers)
        catalog.select { |c| tiers.include?(c[:tier].to_sym) }
      end

      def group_commands
        catalog.select { |c| c[:group] }
      end

      # TG API ожидает массив { command: 'done', description: '...' }.
      # `command` — без слеша, lowercase a-z 0-9 _.
      def tg_format(entries)
        entries.map { |e| { command: e[:cmd].to_s, description: e[:desc].to_s } }
      end
    end
  end
end
