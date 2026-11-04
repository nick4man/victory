# frozen_string_literal: true

module CrmCards
  # «Кто что может с карточками CRM» — для руководителя: перед включением
  # конвейера и после любой смены должностей. На 14.09.26 модерировать
  # было некому — учётка «Генеральный директор» не привязана к Telegram, —
  # и видно это было только отсюда.
  class PermissionsReport
    def lines
      out = ['Права на карточки CRM (должность в Topnlab → возможности)', '']
      ::TelegramUser.active.order(:id).each { |staff| out << staff_line(staff) }
      out << ''
      out << moderators_line
      out.concat(position_drift)
    end

    private

    def staff_line(staff)
      perms = Permissions.for(staff)
      verdict = perms.denial ? "нет прав: #{perms.denial}" : perms.capabilities.join(', ')
      "#{staff.mention} · бот: #{staff.role} · CRM: #{perms.position_title || '—'} → #{verdict}"
    end

    def moderators_line
      moderators = Permissions.moderators
      return '⚠️ Модераторов нет: карточки некому отправить на модерацию.' if moderators.empty?

      "Модераторы: #{moderators.map(&:mention).join(', ')}"
    end

    # Права выдаются по id должности, поэтому переименование в CRM их не
    # ломает, — но устаревшее название в таблице вводит в заблуждение.
    def position_drift
      known = Permissions.positions
      ::User.where(crm_role_id: known.keys).distinct.pluck(:crm_role_id, :crm_role_name).filter_map do |id, name|
        title = known.dig(id.to_s, 'title')
        "⚠️ Должность #{id}: в CRM «#{name}», в config/crm_permissions.yml «#{title}»" if title && title != name
      end
    end
  end
end
