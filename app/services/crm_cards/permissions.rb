# frozen_string_literal: true

module CrmCards
  # Права сотрудника на карточки CRM — наследуются из Topnlab.
  #
  # Источник — должность и статус учётки в CRM (users.crm_role_id,
  # crm_status). Роль в боте (telegram_users.role) прав не даёт: её ставят
  # руками через /promote, и на 14.09.26 она расходится с CRM.
  #
  # Публичный API Topnlab отдаёт должность, но не список прав роли. Поэтому
  # мост «должность → возможности» — config/crm_permissions.yml. Когда
  # появится шлюз к внутреннему API (crm_whoami с модулями роли), таблица
  # заменяется ответом CRM, а Result остаётся прежним.
  #
  # Отказ по умолчанию и всегда с причиной — сотрудник должен понять, что
  # чинить, а не гадать, почему кнопка не работает.
  class Permissions
    CAPABILITIES = %w[create_lead create_object moderate export].freeze
    CONFIG_PATH = Rails.root.join('config/crm_permissions.yml').freeze

    Result = Struct.new(:capabilities, :crm_user, :position_title, :denial, keyword_init: true) do
      def can?(capability)
        denial.nil? && Array(capabilities).include?(capability.to_s)
      end
    end

    def self.for(tg_user)
      new(tg_user).call
    end

    # @return [Array<TelegramUser>] кому карточка уходит на модерацию
    def self.moderators = holders_of(:moderate)

    # @return [Array<TelegramUser>] кто решает, отправлять ли одобренное в CRM.
    # Отдельно от модераторов намеренно: одобрить и выгрузить — разные решения.
    def self.exporters = holders_of(:export)

    # @return [Array<TelegramUser>]
    def self.holders_of(capability)
      scope = ::TelegramUser.active.where.not(topnlab_user_id: nil)
      sandbox_ids = sandbox_capabilities.keys.map(&:to_i)
      scope = scope.or(::TelegramUser.active.where(tg_user_id: sandbox_ids)) if sandbox_ids.any?
      scope.order(:id).select { |staff| self.for(staff).can?(capability) }
    end

    # Только тестовый бот: права по списку TELEGRAM_TEST_CAPABILITIES —
    # JSON { "<tg_user_id>": ["create_lead", ...] } — для тех, кто проверяет
    # песочницу без учётки в CRM. В рабочем боте список не читается вовсе.
    # @return [Hash{String => Array<String>}]
    def self.sandbox_capabilities
      return {} unless Telegram::BotContext.test?

      parsed = JSON.parse(ENV.fetch('TELEGRAM_TEST_CAPABILITIES', '{}'))
      unless parsed.is_a?(Hash)
        Rails.logger.warn('[CrmCards::Permissions] TELEGRAM_TEST_CAPABILITIES — не объект JSON, список игнорирую')
        return {}
      end

      parsed.transform_keys(&:to_s)
    rescue JSON::ParserError
      Rails.logger.warn('[CrmCards::Permissions] TELEGRAM_TEST_CAPABILITIES — не JSON, список игнорирую')
      {}
    end

    # @return [Hash{String => Hash}] crm_role_id → { 'title' =>, 'capabilities' => }
    def self.positions
      YAML.load_file(CONFIG_PATH).fetch('positions', {}).transform_keys(&:to_s)
    end

    def initialize(tg_user)
      @tg_user = tg_user
    end

    def call
      return deny('Сотрудник не найден.') if @tg_user.nil?
      return deny('Аккаунт в боте не активен.') unless @tg_user.status == 'active'

      sandbox = self.class.sandbox_capabilities[@tg_user.tg_user_id.to_s]
      if sandbox
        return Result.new(capabilities: Array(sandbox).map(&:to_s) & CAPABILITIES, crm_user: nil,
                          position_title: 'песочница (TELEGRAM_TEST_CAPABILITIES)', denial: nil)
      end

      return deny('Нет привязки к CRM — выполни /whoami со своим рабочим email.') if @tg_user.topnlab_user_id.blank?

      crm_user = ::User.find_by(crm_user_id: @tg_user.topnlab_user_id)
      unless crm_user
        return deny('Учётки с этим id нет в справочнике сотрудников CRM — он обновляется ночью; ' \
                    'если завтра не появится, повтори /whoami.')
      end

      linked = ::User.find_by(telegram_user_id: @tg_user.id)
      if linked && linked.id != crm_user.id
        return deny('Телеграм привязан к двум разным учёткам CRM — права не выдаются, ' \
                    'пока руководитель не исправит привязку.', crm_user: crm_user)
      end
      # Обе связи должны указывать друг на друга. topnlab_user_id менеджер бота
      # ставит через /link по любому email из CRM без подтверждения — одной
      # этой связи хватило бы, чтобы выдать себе права чужой должности.
      unless crm_user.telegram_user_id == @tg_user.id
        return deny('Учётка CRM не закреплена за этим телеграмом — права не выдаются, ' \
                    'пока руководитель не подтвердит привязку.', crm_user: crm_user)
      end

      return deny("Учётка в CRM не активна (#{crm_user.crm_status}).", crm_user: crm_user) unless crm_user.crm_status == 'active'

      position = self.class.positions[crm_user.crm_role_id.to_s]
      return deny("Должности «#{crm_user.crm_role_name}» в CRM не выданы права на карточки.", crm_user: crm_user) unless position

      Result.new(capabilities: Array(position['capabilities']).map(&:to_s) & CAPABILITIES,
                 crm_user: crm_user, position_title: crm_user.crm_role_name, denial: nil)
    end

    private

    def deny(reason, crm_user: nil)
      Result.new(capabilities: [], crm_user: crm_user, position_title: crm_user&.crm_role_name, denial: reason)
    end
  end
end
