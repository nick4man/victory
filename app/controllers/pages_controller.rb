# frozen_string_literal: true

class PagesController < ApplicationController
  # Skip authentication for all static pages
  # skip_before_action :authenticate_user! # Pages are public
  
  # ============================================
  # STATIC PAGES
  # ============================================
  
  # GET /about
  def about
    set_meta_tags(
      title: 'О компании',
      description: 'АН "Виктори" - надежное агентство недвижимости. Профессиональная команда, индивидуальный подход, прозрачность сделок.',
      keywords: 'о компании, агентство недвижимости, Виктори, о нас'
    )
    
    add_breadcrumb 'О компании'
    
    # Load statistics for about page
    @statistics = {
      years_in_business: Time.current.year - 2010,
      total_deals: Property.where(status: [:sold, :rented]).count,
      active_properties: Property.published.count,
      satisfied_clients: User.clients.count,
      professional_agents: User.agents.count
    }
    
    track_event('about_page_viewed')
  end
  
  # GET /about/team
  def team
    set_meta_tags(
      title: 'Наша команда',
      description: 'Команда профессиональных агентов по недвижимости АН "Виктори"'
    )
    
    add_breadcrumb 'О компании', about_path
    add_breadcrumb 'Команда'
    
    # Load active agents with their statistics
    @agents = User.agents
                  .active
                  .order(created_at: :asc)
                  .includes(:properties)
    
    track_event('team_page_viewed')
  end
  
  # GET /about/history
  def history
    set_meta_tags(
      title: 'История компании',
      description: 'История развития АН "Виктори" с 2010 года до наших дней'
    )
    
    add_breadcrumb 'О компании', about_path
    add_breadcrumb 'История'
    
    # Timeline events
    @timeline = [
      { year: 2010, title: 'Основание компании', description: 'Открытие первого офиса в Москве' },
      { year: 2012, title: 'Расширение', description: 'Открытие 3 дополнительных офисов' },
      { year: 2015, title: '1000 сделок', description: 'Достигнута отметка в 1000 успешных сделок' },
      { year: 2018, title: 'Digital трансформация', description: 'Запуск онлайн-платформы' },
      { year: 2020, title: 'Лидер рынка', description: 'Признание лучшим агентством года' },
      { year: 2024, title: 'Инновации', description: 'AI-рекомендации и виртуальные туры' }
    ]
    
    track_event('history_page_viewed')
  end
  
  # GET /contacts
  def contacts
    set_meta_tags(
      title: 'Контакты',
      description: 'Контактная информация АН "Виктори". Адреса офисов, телефоны, email, режим работы.',
      keywords: 'контакты, адрес, телефон, офисы, график работы'
    )
    
    add_breadcrumb 'Контакты'
    
    # Office locations
    @offices = [
      {
        name: 'Главный офис',
        address: ENV['COMPANY_ADDRESS'] || 'г. Москва, ул. Примерная, д. 1',
        phone: ENV['COMPANY_PHONE'] || '+7 (XXX) XXX-XX-XX',
        email: ENV['COMPANY_EMAIL'] || 'info@viktory-realty.ru',
        working_hours: 'Пн-Пт: 9:00-21:00, Сб-Вс: 10:00-18:00',
        coordinates: [55.7558, 37.6173] # Moscow center
      }
    ]
    
    # Contact form object
    @contact_form = ContactForm.new if defined?(ContactForm)
    
    track_event('contacts_page_viewed')
  end
  
  # POST /contacts
  def send_contact_form
    if check_spam
      flash[:alert] = 'Слишком много запросов. Попробуйте позже.'
      redirect_to contacts_path and return
    end

    contact = contact_form_params
    @name    = contact[:name]
    @email   = contact[:email]
    @phone   = contact[:phone]
    @message = contact[:message]
    @subject = contact[:subject].presence || 'Общий вопрос'

    # Validate
    if @name.blank? || @email.blank? || @message.blank?
      flash[:alert] = 'Пожалуйста, заполните все обязательные поля'
      redirect_to contacts_path
      return
    end

    unless valid_email?(@email)
      flash[:alert] = 'Пожалуйста, укажите корректный email'
      redirect_to contacts_path
      return
    end

    # Create inquiry
    inquiry = Inquiry.create(
      inquiry_type: :contact_agent,
      status: :new,
      name: @name,
      email: @email,
      phone: @phone,
      message: @message,
      source: 'contact_form',
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )

    if inquiry.persisted?
      # Send email
      # ContactMailer.contact_form(@name, @email, @phone, @subject, @message).deliver_later

      track_event('contact_form_submitted', {
        subject: @subject,
        inquiry_id: inquiry.id
      })

      flash[:notice] = 'Спасибо за обращение! Мы свяжемся с вами в ближайшее время.'
      redirect_to contacts_path
    else
      flash[:alert] = 'Ошибка при отправке сообщения. Попробуйте позже.'
      redirect_to contacts_path
    end
  end
  
  # GET /services
  def services
    set_meta_tags(
      title: 'Наши услуги',
      description: 'Полный спектр услуг по недвижимости: покупка, продажа, аренда, ипотека, юридическое сопровождение.',
      keywords: 'услуги, недвижимость, ипотека, юридические услуги, оценка'
    )
    
    add_breadcrumb 'Услуги'
    
    # Services list
    @services = [
      {
        icon: '🏠',
        title: 'Подбор недвижимости',
        description: 'Поможем найти идеальную квартиру или дом с учетом всех ваших пожеланий',
        link: properties_path
      },
      {
        icon: '💰',
        title: 'Ипотечное кредитование',
        description: 'Подбор оптимальных ипотечных программ от ведущих банков',
        link: services_mortgage_calculator_path
      },
      {
        icon: '⚖️',
        title: 'Юридическое сопровождение',
        description: 'Полное юридическое сопровождение сделок купли-продажи',
        link: services_legal_services_path
      },
      {
        icon: '📊',
        title: 'Оценка недвижимости',
        description: 'Профессиональная оценка рыночной стоимости вашей недвижимости',
        link: sell_evaluation_path
      },
      {
        icon: '📄',
        title: 'Помощь с документами',
        description: 'Подготовка и проверка документов для сделок',
        link: services_document_services_path
      },
      {
        icon: '🎥',
        title: 'Виртуальные туры',
        description: '3D-туры по объектам недвижимости с эффектом присутствия',
        link: services_virtual_tours_path
      }
    ]
    
    track_event('services_page_viewed')
  end
  
  # GET /faq
  def faq
    set_meta_tags(
      title: 'Часто задаваемые вопросы (FAQ)',
      description: 'Ответы на часто задаваемые вопросы о покупке, продаже и аренде недвижимости',
      keywords: 'faq, вопросы, ответы, помощь'
    )
    
    add_breadcrumb 'FAQ'
    
    # FAQ categories and questions
    @faq_categories = {
      'Покупка недвижимости' => [
        {
          question: 'Как оформить покупку квартиры?',
          answer: 'Процесс покупки включает: выбор объекта, проверку документов, заключение договора, регистрацию в Росреестре. Мы сопровождаем вас на всех этапах.'
        },
        {
          question: 'Можно ли купить квартиру в ипотеку?',
          answer: 'Да, мы работаем со всеми крупными банками. Поможем подобрать оптимальные условия кредитования и оформить заявку.'
        },
        {
          question: 'Сколько времени занимает сделка?',
          answer: 'В среднем от 2 до 4 недель с момента подписания предварительного договора до получения ключей.'
        }
      ],
      'Продажа недвижимости' => [
        {
          question: 'Как быстро можно продать квартиру?',
          answer: 'Средний срок продажи составляет 1-3 месяца в зависимости от цены и состояния объекта.'
        },
        {
          question: 'Какие документы нужны для продажи?',
          answer: 'Необходимы: свидетельство о собственности, техпаспорт, выписка из ЕГРН, согласие супруга (если есть).'
        },
        {
          question: 'Как определить правильную цену?',
          answer: 'Мы проводим бесплатную оценку с анализом рынка и сопоставимых объектов.'
        }
      ],
      'Аренда' => [
        {
          question: 'Нужен ли залог при аренде?',
          answer: 'Обычно требуется залог в размере месячной арендной платы, который возвращается при выезде.'
        },
        {
          question: 'Можно ли снимать квартиру с детьми и питомцами?',
          answer: 'Да, в каталоге есть фильтр "Можно с питомцами" для поиска подходящих вариантов.'
        }
      ],
      'Ипотека' => [
        {
          question: 'Какой минимальный первоначальный взнос?',
          answer: 'Обычно от 10-15% от стоимости недвижимости, но некоторые банки требуют 20%.'
        },
        {
          question: 'Можно ли получить ипотеку без справки о доходах?',
          answer: 'Да, некоторые банки предлагают программы по двум документам, но ставка будет выше.'
        }
      ]
    }
    
    track_event('faq_page_viewed')
  end
  
  # GET /privacy
  def privacy
    set_meta_tags(
      title: 'Политика конфиденциальности',
      description: 'Политика конфиденциальности АН "Виктори" - защита персональных данных',
      robots: 'noindex, follow'
    )
    
    add_breadcrumb 'Политика конфиденциальности'
    
    @last_updated = Date.new(2024, 1, 1) # Update this date when policy changes
    
    track_event('privacy_page_viewed')
  end
  
  # GET /terms
  def terms
    set_meta_tags(
      title: 'Пользовательское соглашение',
      description: 'Условия использования сайта АН "Виктори"',
      robots: 'noindex, follow'
    )
    
    add_breadcrumb 'Пользовательское соглашение'
    
    @last_updated = Date.new(2024, 1, 1) # Update this date when terms change
    
    track_event('terms_page_viewed')
  end
  
  # GET /404
  def not_found
    render file: Rails.public_path.join('404.html'), 
           status: :not_found, 
           layout: false,
           content_type: 'text/html'
  end
  
  # GET /422
  def unprocessable_entity
    render file: Rails.public_path.join('422.html'), 
           status: :unprocessable_entity, 
           layout: false,
           content_type: 'text/html'
  end
  
  # GET /500
  def internal_server_error
    render file: Rails.public_path.join('500.html'), 
           status: :internal_server_error, 
           layout: false,
           content_type: 'text/html'
  end
  
  private
  
  # ============================================
  # STRONG PARAMETERS
  # ============================================

  def contact_form_params
    params.permit(:name, :email, :phone, :message, :subject)
  end

  # ============================================
  # CONTACT FORM VALIDATION
  # ============================================

  def validate_contact_form
    errors = []
    
    errors << 'Имя не может быть пустым' if params[:name].blank?
    errors << 'Email не может быть пустым' if params[:email].blank?
    errors << 'Некорректный email' if params[:email].present? && !valid_email?(params[:email])
    errors << 'Сообщение не может быть пустым' if params[:message].blank?
    
    errors
  end
  
  def valid_email?(email)
    email.match?(URI::MailTo::EMAIL_REGEXP)
  end
  
end