# frozen_string_literal: true

# Contact Forms Controller
# Handles various contact forms (quick inquiry, viewing schedule, callback, etc.)
class ContactFormsController < ApplicationController
  before_action :set_property, only: [:viewing_schedule, :property_inquiry]
  # #262: антиспам-гейт до создания Inquiry и любых mailer'ов — каждая заявка
  # жжёт почту, включая confirmation на адрес из формы. CSRF здесь не барьер:
  # бот честно скачивает форму и шлёт валидный токен (JSON без токена в
  # production и так отклоняется fail-closed до гейта). Дроп молчаливый:
  # ответ повторяет success-форму экшена, бот не узнаёт о блокировке (#255).
  # Объявлен ПОСЛЕ set_property: дроп viewing_schedule редиректит на @property.
  before_action :drop_spam_submission, only: %i[
    quick_inquiry viewing_schedule callback consultation mortgage_application property_selection
  ]

  # Success-формы заявочных экшенов — единый источник: их же отдаёт дроп гейта,
  # чтобы заблокированный бот не отличил молчаливый дроп от принятой заявки.
  SUBMIT_SUCCESS = {
    'quick_inquiry'        => { notice: 'Спасибо! Ваша заявка принята. Мы свяжемся с вами в ближайшее время.', message: 'Заявка принята' },
    'viewing_schedule'     => { notice: 'Запись на показ принята! Мы свяжемся с вами для подтверждения.', message: 'Запись принята' },
    'callback'             => { notice: 'Заявка на звонок принята! Мы перезвоним вам в течение 15 минут.', message: 'Заявка принята' },
    'consultation'         => { notice: 'Заявка на консультацию принята! Мы свяжемся с вами для согласования времени.', message: 'Заявка принята' },
    'mortgage_application' => { notice: 'Заявка на ипотеку принята! Мы подберем для вас лучшие предложения.', message: 'Заявка принята' },
    'property_selection'   => { notice: 'Заявка принята! Мы подберем для вас подходящие варианты и пришлем на email.', message: 'Заявка принята' }
  }.freeze

  # POST /contact_forms/quick_inquiry
  def quick_inquiry
    @inquiry = Inquiry.new(quick_inquiry_params)
    @inquiry.inquiry_type = 'quick_inquiry'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    @inquiry.ip_address = request.remote_ip
    @inquiry.user_agent = request.user_agent

    if @inquiry.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # Send notifications
      InquiryMailer.new_inquiry_notification(@inquiry).deliver_later
      InquiryMailer.inquiry_confirmation(@inquiry).deliver_later if @inquiry.email.present?

      # Track event
      track_event('quick_inquiry_submitted', {
        inquiry_id: @inquiry.id,
        property_id: @inquiry.property_id
      })

      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: SUBMIT_SUCCESS.dig('quick_inquiry', :notice) }
        format.json { render json: submit_success_json('quick_inquiry', record_id: @inquiry.id), status: :created }
      end
    else
      # Сабмит прошёл гейт, но не сохранился: маркеры освобождаются, иначе
      # исправленный повтор был бы молча отброшен (блокер 2 из ревью #262).
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # POST /contact_forms/viewing_schedule
  def viewing_schedule
    @viewing = ViewingSchedule.new(viewing_params)
    @viewing.user = current_user if user_signed_in?
    @viewing.property = @property
    @viewing.status = 'pending'

    if @viewing.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # Create inquiry
      create_viewing_inquiry(@viewing)

      # Mailer'ы НЕ дублируем: viewing_requested/viewing_confirmation шлёт
      # after_create :send_notifications модели — единый источник уведомлений
      # для всех путей создания записи (явные deliver_later здесь давали
      # клиенту и менеджерам по два одинаковых письма).

      track_event('viewing_scheduled', {
        viewing_id: @viewing.id,
        property_id: @property.id,
        preferred_date: @viewing.preferred_date
      })

      respond_to do |format|
        format.html { redirect_to property_path(@property), notice: SUBMIT_SUCCESS.dig('viewing_schedule', :notice) }
        format.json { render json: submit_success_json('viewing_schedule', record_id: @viewing.id), status: :created }
      end
    else
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_to property_path(@property), alert: "Ошибка: #{@viewing.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @viewing.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # POST /contact_forms/callback
  def callback
    @inquiry = Inquiry.new(callback_params)
    @inquiry.inquiry_type = 'callback'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    @inquiry.priority = determine_priority(@inquiry)

    if @inquiry.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # Send notifications
      InquiryMailer.callback_requested(@inquiry).deliver_later

      # Send SMS to managers if urgent
      send_urgent_sms(@inquiry) if @inquiry.priority == 'urgent'

      # Create CRM task
      create_crm_task(@inquiry, 'callback')

      track_event('callback_requested', {
        inquiry_id: @inquiry.id,
        phone: @inquiry.phone,
        preferred_time: @inquiry.metadata&.dig('preferred_time')
      })

      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: SUBMIT_SUCCESS.dig('callback', :notice) }
        format.json { render json: submit_success_json('callback'), status: :created }
      end
    else
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # POST /contact_forms/consultation
  def consultation
    @inquiry = Inquiry.new(consultation_params)
    @inquiry.inquiry_type = 'consultation'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'

    if @inquiry.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # Send notifications
      InquiryMailer.consultation_requested(@inquiry).deliver_later

      # Create calendar event for agent
      create_calendar_event(@inquiry) if @inquiry.metadata&.dig('preferred_date').present?

      track_event('consultation_requested', {
        inquiry_id: @inquiry.id,
        consultation_type: @inquiry.metadata&.dig('consultation_type')
      })

      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: SUBMIT_SUCCESS.dig('consultation', :notice) }
        format.json { render json: submit_success_json('consultation'), status: :created }
      end
    else
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # POST /contact_forms/mortgage_application
  def mortgage_application
    @inquiry = Inquiry.new(mortgage_params)
    @inquiry.inquiry_type = 'mortgage'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'

    if @inquiry.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # Send to mortgage partners
      send_to_mortgage_partners(@inquiry)

      # Send notifications
      InquiryMailer.mortgage_application_received(@inquiry).deliver_later

      track_event('mortgage_application_submitted', {
        inquiry_id: @inquiry.id,
        property_price: @inquiry.metadata&.dig('property_price'),
        down_payment: @inquiry.metadata&.dig('down_payment')
      })

      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: SUBMIT_SUCCESS.dig('mortgage_application', :notice) }
        format.json { render json: submit_success_json('mortgage_application'), status: :created }
      end
    else
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  # POST /contact_forms/property_selection
  def property_selection
    @inquiry = Inquiry.new(selection_params)
    # #262: enum Inquiry не знает 'property_selection' (см. db/seeds.rb) —
    # присваивание значения вне enum роняло легитимный сабмит ArgumentError
    # ещё до save. Подбор вариантов — заявка агенту: ближайший существующий тип.
    @inquiry.inquiry_type = 'contact_agent'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'

    if @inquiry.save
      # Слот rate limit уже зарезервирован гейтом атомарно (до side effects).
      # AI-powered property matching
      matching_properties = find_matching_properties(@inquiry)
      @inquiry.update(metadata: @inquiry.metadata.merge(matching_count: matching_properties.count))

      # Send notifications with matches
      # #262: Relation не сериализуется в аргументы job (500 на легитимном
      # сабмите) — в mailer уходит материализованный массив.
      InquiryMailer.property_selection_request(@inquiry, matching_properties.to_a).deliver_later

      track_event('property_selection_requested', {
        inquiry_id: @inquiry.id,
        criteria: @inquiry.metadata
      })

      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: SUBMIT_SUCCESS.dig('property_selection', :notice) }
        format.json { render json: submit_success_json('property_selection', matching_count: matching_properties.count), status: :created }
      end
    else
      contact_form_spam_gate.release_submission_markers!
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  private

  # #262: молчаливый дроп заявочных форм — гейт сработал, логируем и отвечаем
  # success-формой экшена (SUBMIT_SUCCESS + та же JSON-схема), ничего не создавая
  # и не отправляя. Срабатывает как before_action: render/redirect обрывает
  # цепочку до экшена.
  def drop_spam_submission
    gate = contact_form_spam_gate
    return unless gate.call.spam

    gate.record(ua: request.user_agent)
    success = SUBMIT_SUCCESS.fetch(action_name)
    respond_to do |format|
      format.html do
        if action_name == 'viewing_schedule' && @property
          redirect_to property_path(@property), notice: success[:notice]
        else
          redirect_back fallback_location: root_path, notice: success[:notice]
        end
      end
      format.json { render json: submit_success_json(action_name), status: :created }
    end
  end

  # Один экземпляр гейта на запрос: before_action резервирует reason, маркер
  # идемпотентности и слот rate limit, а success/failure-пути экшена работают
  # с тем же состоянием (release_submission_markers!), а не со свежим объектом.
  def contact_form_spam_gate
    @contact_form_spam_gate ||= public_form_spam_gate(action_name)
  end

  # Единый success-контракт заявочных экшенов (блокер 4 из ревью #262):
  # настоящий успех и молчаливый дроп гейта отдают одну JSON-схему — те же
  # ключи и типы, чтобы бот не отличил блокировку от принятой заявки. У дропа
  # record_id/matching_count отсутствуют — подставляются правдоподобные
  # значения, реальной записи за ними нет.
  def submit_success_json(action, record_id: nil, matching_count: nil)
    payload = { success: true, message: SUBMIT_SUCCESS.dig(action, :message) }
    case action
    when 'quick_inquiry'      then payload[:inquiry_id]     = record_id || fake_public_id
    when 'viewing_schedule'   then payload[:viewing_id]     = record_id || fake_public_id
    when 'property_selection' then payload[:matching_count] = matching_count || SecureRandom.random_number(11)
    end
    payload
  end

  # Правдоподобный id для молчаливого дропа: бот не должен отличить
  # placeholder от настоящего последовательного id заявки.
  def fake_public_id
    SecureRandom.random_number(900_000) + 100_000
  end

  def quick_inquiry_params
    params.require(:inquiry).permit(:name, :phone, :email, :message, :property_id, :external_listing_id)
  end

  def viewing_params
    params.require(:viewing_schedule).permit(
      :name, :phone, :email, :preferred_date, :preferred_time, :message
    )
  end

  def callback_params
    params.require(:inquiry).permit(:name, :phone, :preferred_time, :message).tap do |p|
      p[:metadata] = { preferred_time: params.dig(:inquiry, :preferred_time) }
    end
  end

  def consultation_params
    # #262: consultation_type — не колонка inquiries (уходит в metadata ниже),
    # в permit ей не место: Inquiry.new падал с UnknownAttributeError на любом
    # легитимном сабмите.
    params.require(:inquiry).permit(:name, :phone, :email, :message, :preferred_date).tap do |p|
      p[:metadata] = {
        consultation_type: params.dig(:inquiry, :consultation_type),
        preferred_date: params.dig(:inquiry, :preferred_date)
      }
    end
  end

  def mortgage_params
    # #262: финансовые поля — не колонки inquiries, только metadata (см. выше).
    params.require(:inquiry).permit(:name, :phone, :email, :property_id).tap do |p|
      p[:metadata] = {
        property_price: params.dig(:inquiry, :property_price),
        down_payment: params.dig(:inquiry, :down_payment),
        loan_term: params.dig(:inquiry, :loan_term),
        monthly_income: params.dig(:inquiry, :monthly_income)
      }
    end
  end

  def selection_params
    # #262: критерии подбора — не колонки inquiries, только metadata (см. выше).
    params.require(:inquiry).permit(:name, :phone, :email, :message).tap do |p|
      p[:metadata] = {
        property_type: params.dig(:inquiry, :property_type),
        deal_type: params.dig(:inquiry, :deal_type),
        min_price: params.dig(:inquiry, :min_price),
        max_price: params.dig(:inquiry, :max_price),
        rooms: params.dig(:inquiry, :rooms),
        district: params.dig(:inquiry, :district)
      }
    end
  end

  def set_property
    @property = Property.friendly.find(params[:property_id]) if params[:property_id].present?
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: 'Объект не найден'
  end

  def determine_priority(inquiry)
    # Urgent if callback requested in next 2 hours or during business hours
    now = Time.current
    business_hours = (9..18).cover?(now.hour) && now.wday.between?(1, 5)
    business_hours ? 'urgent' : 'normal'
  end

  def create_viewing_inquiry(viewing)
    Inquiry.create!(
      user: viewing.user,
      property: viewing.property,
      inquiry_type: 'viewing',
      status: 'new',
      name: viewing.name,
      phone: viewing.phone,
      email: viewing.email,
      message: "Запись на показ: #{viewing.preferred_date} в #{viewing.preferred_time}",
      source: 'website',
      metadata: {
        viewing_id: viewing.id,
        preferred_date: viewing.preferred_date,
        preferred_time: viewing.preferred_time
      }
    )
  end

  def find_matching_properties(inquiry)
    criteria = inquiry.metadata

    scope = Property.active
                    .where(property_type: criteria['property_type'])
                    .where(deal_type: criteria['deal_type'])
                    .where('price >= ? AND price <= ?', criteria['min_price'], criteria['max_price'])

    scope = scope.where(rooms: criteria['rooms']) if criteria['rooms'].present?
    scope.limit(10)
  end

  def create_crm_task(inquiry, task_type)
    Rails.logger.info "Creating CRM task '#{task_type}' for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to create CRM task: #{e.message}"
  end

  def send_urgent_sms(inquiry)
    # SMS notification for urgent callbacks
    Rails.logger.info "Sending urgent SMS for inquiry ##{inquiry.id}"
    # SmscService.send_sms(inquiry.phone, "Urgent callback request") if defined?(SmscService)
  rescue StandardError => e
    Rails.logger.error "Failed to send SMS: #{e.message}"
  end

  def create_calendar_event(inquiry)
    Rails.logger.info "Creating calendar event for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to create calendar event: #{e.message}"
  end

  def send_to_mortgage_partners(inquiry)
    Rails.logger.info "Sending mortgage application to partners for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to send to mortgage partners: #{e.message}"
  end
end
