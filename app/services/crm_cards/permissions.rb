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
    CAPABILITIES = %w[create_lead create_object moderate].freeze
    CONFIG_PATH = Rails.root.join('config/crm_permissions.yml').freeze

    Result = Struct.new(:capabilities, :crm_user, :position_title, :denial, keyword_init: true) do
      def can?(capability)
        denial.nil? && Array(capabilities).include?(capability.to_s)
      end
    end

    def self.for(tg_user)
      new(tg_user).call
    end

    # @return [Array<TelegramUser>]
    def self.moderators
      ::TelegramUser.active.where.not(topnlab_user_id: nil).order(:id).select { |staff| self.for(staff).can?(:moderate) }
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
