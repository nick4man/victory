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

      # Считаем только фактически отправленное: ask глотает исключение, чтобы
      # один сбой не ронял рассылку остальным, и без возвращаемого значения в
      # сводке «отправлено: N» оказывались бы неотправленные тоже.
      sent += 1 if ask(agent, property)
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

  # Статусы, при которых объект уже никуда не поедет: спрашивать про них
  # собственника бессмысленно и вредно.
  CLOSED_STATUSES = %i[sold rented archived rejected].freeze

  # Объекты, по которым вопрос уместен: собственника нет, агент не отказался,
  # отсрочка истекла — и объект вообще претендует на витрину.
  #
  # Фильтр по deal_state/status обязателен. Без него в выборку попадают 28
  # закрытых сделок и 37 отложенных, а `.order(:updated_at)` поднимает их
  # наверх — синк перестал их трогать, поэтому они «самые старые». Агент
  # получил бы «объект не попадает на витрину» про проданный в мае участок, и
  # только четырнадцатым по счёту — вопрос, который действительно снимает
  # блокировку публикации.
  #
  # `signed_agency_contract_at: nil` — по той же причине, но случай хуже.
  # Прогон 14.08.26: из 25 объектов в очереди 17 уже на витрине. Подпись им
  # проставила миграция при внедрении гейта D5, записи о собственнике при этом
  # не появилось — формально `owner_user_id` пуст, фактически объект
  # опубликован. Агент получил бы «не попадает на витрину» про карточку,
  # открытую на сайте. Собрать собственников по ним всё равно стоит, но это
  # другая задача и другой текст, а не блокировка публикации.
  def pending_scope(agent)
    Property.where(user_id: agent.id, owner_user_id: nil, deleted_at: nil)
            .where(signed_agency_contract_at: nil)
            .where(deal_state: Property::PUBLISHABLE_DEAL_STATES)
            .where.not(status: CLOSED_STATUSES)
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
    true
  rescue StandardError => e
    # Один недоставленный вопрос не должен ронять рассылку остальным.
    Rails.logger.warn("[OwnerRequest] не отправлено agent=#{agent.id} property=#{property.id}: #{e.class}: #{e.message}")
    false
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
