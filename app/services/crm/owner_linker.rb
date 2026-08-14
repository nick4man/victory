# frozen_string_literal: true

module Crm
  # Поиск или создание клиента-собственника и привязка его к объекту.
  #
  # Вынесено из Topnlab::OwnerSyncService, потому что источников собственника
  # стало два: выгрузка из Topnlab и контакт, присланный агентом в телеграм.
  # Правила нормализации телефона и поиска дубля обязаны совпадать — иначе один
  # человек, пришедший разными путями, заведётся дважды, и объекты у него
  # разъедутся по двум учёткам.
  #
  #   Crm::OwnerLinker.from_topnlab(data)                    # => [user, created?]
  #   Crm::OwnerLinker.from_contact(phone: '+7…', first_name: 'Иван')
  #   Crm::OwnerLinker.attach!(property, user)
  class OwnerLinker
    # Минимум, при котором учётка вообще имеет смысл: без email и телефона
    # связаться с человеком нельзя, а magic-link отправить некуда.
    def self.from_topnlab(data)
      new(
        first_name: data['firstname'],
        last_name: data['lastname'],
        middle_name: data['fathername'],
        email: extract_topnlab_email(data),
        phone: extract_topnlab_phone(data),
        crm_user_id: data['id'].to_i
      ).call
    end

    # @param phone [String, nil] в любом виде, нормализуется внутри
    def self.from_contact(first_name: nil, last_name: nil, phone: nil, email: nil)
      new(first_name: first_name, last_name: last_name, phone: phone, email: email).call
    end

    # Привязка к объекту. update_column, а не update: Property тянет за собой
    # тяжёлые колбэки (перестроение эмбеддингов, пуш в фиды), а здесь меняется
    # одно поле связи, не влияющее на содержание карточки.
    #
    # @return [Boolean] false, если у объекта уже есть собственник
    def self.attach!(property, user)
      return false if property.owner_user_id.present?

      property.update_column(:owner_user_id, user.id) # rubocop:disable Rails/SkipsModelValidations
      true
    end

    # Topnlab отдаёт контакты либо строкой, либо массивом хешей с признаком
    # основного: [{ 'value' => '…', 'is_main' => 1 }, …]
    def self.extract_topnlab_email(data)
      pick_topnlab_value(data['emails'] || data['email'])&.downcase
    end

    def self.extract_topnlab_phone(data)
      pick_topnlab_value(data['phones'] || data['phone'])
    end

    def self.pick_topnlab_value(raw)
      case raw
      when Array
        main = raw.find { |e| e.is_a?(Hash) && e['is_main'].to_i == 1 } || raw.first
        (main.is_a?(Hash) ? main['value'] : main).to_s.strip.presence
      when String
        raw.strip.presence
      end
    end
    private_class_method :pick_topnlab_value

    # Приводим к +7XXXXXXXXXX. Российские номера пишут и с 8, и с +7, и с
    # пробелами — без единого вида поиск дубля не находит существующего
    # человека и заводит второго.
    def self.normalize_phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      return nil if digits.empty?

      # Голые десять цифр — самый частый ответ агента («Светлана 9001234567»),
      # и раньше он давал `+9001234567`, без кода страны. Правило перенесено из
      # Topnlab-синка, где на вход приходили номера вида `79…`, и на свободном
      # тексте ломалось: в проде уже лежит `+9209780508`.
      return "+7#{digits}" if digits.length == 10

      digits.start_with?('7', '8') ? "+7#{digits[-10..]}" : "+#{digits}"
    end

    # DLP для логов. Те же правила, что в CabinetInvitationSmsService#mask и
    # CabinetInvitationDispatcher#mask_email — лог должен давать опознать
    # запись при разборе инцидента, но не читаться как выгрузка контактов.
    def self.mask_email(email)
      local, domain = email.to_s.split('@')
      return 'nil' if email.blank?
      return '***' if domain.blank?

      "#{local[0..1]}***@#{domain}"
    end

    def self.mask_phone(phone)
      digits = phone.to_s.gsub(/\D/, '')
      return 'nil' if phone.blank?
      return '****' if digits.length < 4

      "***#{digits.last(4)}"
    end

    def initialize(first_name: nil, last_name: nil, middle_name: nil,
                   email: nil, phone: nil, crm_user_id: nil)
      @first_name  = first_name.to_s.strip.presence
      @last_name   = last_name.to_s.strip.presence
      @middle_name = middle_name.to_s.strip.presence
      @email       = email.to_s.strip.downcase.presence
      @phone       = phone.to_s.strip.presence
      @crm_user_id = crm_user_id
    end

    # @return [Array(User, Boolean)] найденный или созданный клиент и признак
    #   создания. [nil, false] — данных не хватило или запись не сохранилась.
    def call
      existing = find_existing
      return [existing, false] if existing
      return [nil, false] if @email.blank? && @phone.blank?

      user = User.new(build_attrs)
      # validate: false — тот же приём, что в исходном OwnerSyncService: у
      # клиента, заведённого не им самим, нет пароля и подтверждённого email,
      # а модель этого требует.
      return [user, true] if user.save(validate: false)

      Rails.logger.warn("[OwnerLinker] не удалось создать клиента: #{user.errors.full_messages.inspect}")
      [nil, false]
    rescue ActiveRecord::RecordNotUnique
      # Две разные ситуации с одинаковым исключением.
      #
      # Гонка: пока искали, того же человека завёл параллельный процесс —
      # повторный поиск его найдёт.
      #
      # Занятый контакт: email или телефон принадлежат мягко удалённой учётке.
      # Поиск её не видит (deleted_at), а unique-индекс продолжает держать. Тогда
      # возвращаем nil, а не воскрешаем запись: удаление могло быть по 152-ФЗ, и
      # молча вернуть человека в систему нельзя. Логируем так, чтобы причина
      # читалась — иначе в проде это выглядит как необъяснимый отказ.
      #
      # Контакты — в маскированном виде: ветка срабатывает ровно на человеке,
      # который потребовал удаления своих данных, и писать его почту с телефоном
      # открытым текстом в лог — воспроизводить то, что он просил стереть.
      found = find_existing
      if found.nil?
        Rails.logger.warn(
          '[OwnerLinker] контакт занят удалённой учёткой, клиент не создан: ' \
          "email=#{self.class.mask_email(@email)} phone=#{self.class.mask_phone(@phone)}"
        )
      end
      [found, false]
    end

    private

    def find_existing
      scope = User.where(deleted_at: nil, active: true)

      if @email.present?
        found = scope.find_by('LOWER(email) = ?', @email)
        return found if found
      end

      return nil if @phone.blank?

      digits = @phone.gsub(/\D/, '').last(10)
      return nil if digits.length < 10

      # Совпадение по телефону ищем только среди клиентов и агентов: админская
      # учётка с тем же номером не должна стать «собственником» объекта.
      scope.where(role: %i[client agent]).where('phone LIKE ?', "%#{digits}").first
    end

    def build_attrs
      attrs = {
        first_name: @first_name || 'Клиент',
        last_name: @last_name || '—',
        middle_name: @middle_name,
        role: :client,
        active: true,
        password: SecureRandom.urlsafe_base64(32),
        crm_synced_at: Time.current
      }
      attrs[:crm_user_id] = @crm_user_id if @crm_user_id.to_i.positive?
      attrs[:email] = @email if @email.present?
      attrs[:phone] = self.class.normalize_phone(@phone) if @phone.present?
      attrs
    end
  end
end
