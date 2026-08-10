# frozen_string_literal: true

# Спрашивает у агентов, кто собственник их объектов, застрявших до витрины.
#
# Объект не публикуется, пока собственник не подписал агентский договор в
# кабинете. Кабинет находит объекты по owner_user_id, а он пуст у всех карточек:
# Topnlab связь продавца с объектом не отдаёт (`/clients/get-by-entity` даёт
# пустой список), в карточке объекта контакта тоже нет. Знает собственника
# только агент — у него и спрашиваем.
#
# **По одному объекту на агента за прогон.** У одного агента 44 таких объекта;
# сорок четыре сообщения подряд превращают бота в спам, после чего его замьютят
# вместе со всеми остальными уведомлениями — включая заявки. Следующий вопрос
# уходит, когда на предыдущий ответили либо истёк срок ожидания.
class OwnerRequestJob < ApplicationJob
  queue_as :scheduled

  # Сколько ждём ответа, прежде чем спросить про этот объект снова.
  REASK_AFTER = 3.days

  def perform
    sent = 0
    skipped_unreachable = 0

    User.where(role: %i[agent admin], active: true, deleted_at: nil)
        .includes(:telegram_user)
        .find_each do |agent|
      reason = Crm::TelegramReachability.for(agent)
      if reason != :ok
        # Не ошибка джоба: причина известна и чинится в другом месте (экран
        # связывания или сам сотрудник, открывший личку). Логируем, чтобы
        # молчание бота не выглядело поломкой.
        skipped_unreachable += 1
        Rails.logger.info("[OwnerRequest] пропускаю #{agent.id}: #{Crm::TelegramReachability.explain(reason)}")
        next
      end

      next if awaiting_reply?(agent)

      property = next_property_for(agent)
      next if property.nil?

      ask(agent, property)
      sent += 1
    end

    Rails.logger.info("[OwnerRequest] отправлено: #{sent}, недостижимы: #{skipped_unreachable}")
    { sent: sent, skipped_unreachable: skipped_unreachable }
  end

  private

  # Уже спросили и ждём — второй вопрос тому же человеку сейчас не задаём.
  def awaiting_reply?(agent)
    pending_scope(agent).where(owner_request_sent_at: REASK_AFTER.ago..).exists?
  end

  def next_property_for(agent)
    pending_scope(agent)
      .where(owner_request_sent_at: nil)
      .or(pending_scope(agent).where(owner_request_sent_at: ...REASK_AFTER.ago))
      .order(:updated_at)
      .first
  end

  # Объекты, по которым вопрос уместен: собственника нет, агент не отказался,
  # отсрочка истекла.
  def pending_scope(agent)
    Property.where(user_id: agent.id, owner_user_id: nil, deleted_at: nil)
            .where(owner_request_declined_at: nil)
            .where('owner_request_snoozed_until IS NULL OR owner_request_snoozed_until <= ?', Time.current)
  end

  def ask(agent, property)
    Telegram::Client.new.send_message(
      text_for(property),
      chat_id: agent.telegram_user.dm_chat_id,
      parse_mode: 'HTML',
      reply_markup: keyboard_for(property)
    )
    property.update_columns( # rubocop:disable Rails/SkipsModelValidations
      owner_request_sent_at: Time.current, updated_at: Time.current
    )
  rescue StandardError => e
    # Один недоставленный вопрос не должен ронять рассылку остальным.
    Rails.logger.warn("[OwnerRequest] не отправлено agent=#{agent.id} property=#{property.id}: #{e.class}: #{e.message}")
  end

  def text_for(property)
    details = [
      property.area.present? ? "#{property.area} м²" : nil,
      property.price.present? ? "#{ActiveSupport::NumberHelper.number_to_delimited(property.price.to_i)} ₽" : nil
    ].compact.join(', ')

    "<b>Объект #{label(property)}</b>#{details.present? ? "\n#{details}" : ''}\n\n" \
      "Не попадает на витрину: в системе нет собственника, а без него некому подписать договор.\n" \
      'Кто владелец?'
  end

  def keyboard_for(property)
    { inline_keyboard: [
      [{ text: '📇 Прислать контакт', callback_data: "owner:contact:#{property.id}" }],
      [{ text: '🕒 Отложить', callback_data: "owner:snooze:#{property.id}" },
       { text: '🚫 Не мой объект', callback_data: "owner:decline:#{property.id}" }]
    ] }
  end

  def label(property)
    parts = [property.district.presence, property.address.presence].compact
    "##{property.id}#{parts.any? ? " — #{parts.join(', ')}" : ''}"
  end
end
