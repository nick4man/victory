# frozen_string_literal: true

# АН "Виктори" - Routes Configuration
# Digital Platform for Real Estate Agency

require 'sidekiq/web'

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # ============================================
  # SIDEKIQ DASHBOARD (admin only)
  # ============================================
  # Phase 10 Iter 16 — Devise effectively off, поэтому `authenticate :user`
  # блокирует всех. Альтернатива: token-based constraint (ADMIN_TOKEN).
  # Защищает Sidekiq Web UI пока Devise не вернётся.
  sidekiq_admin = lambda do |request|
    expected = ENV['ADMIN_TOKEN'].to_s
    return false if expected.blank?

    provided = request.params['token'].to_s
    ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  constraints(sidekiq_admin) do
    mount Sidekiq::Web => '/sidekiq'
  end

  # ============================================
  # ADMIN PANEL (ActiveAdmin) - Temporarily disabled
  # ============================================
  # devise_for :admin_users, ActiveAdmin::Devise.config
  # ActiveAdmin.routes(self)

  # ============================================
  # USER AUTHENTICATION (Devise)
  # ============================================
  devise_for :users

  # ============================================
  # MAIN ROUTES
  # ============================================
  
  # Homepage (using minimal landing page for design work)
  root 'landing#index'

  # ============================================
  # FOREIGN INVESTORS (Phase B-MVP — EN landing)
  # ============================================
  # /foreign — EN-language landing для международных инвесторов.
  # i18n.locale=:en для request lifecycle (set в ForeignController).
  get 'foreign', to: 'foreign#index', as: :foreign

  # B2: /foreign/audits — EN investment audit flow с RUB+USD primary,
  # multi-currency conversion table, LLM-generated visa/residency chapter.
  # Wraps existing InvestmentAuditJob через PropertyValuation
  # metadata['audit_locale']='en'.
  namespace :foreign do
    resources :audits, only: %i[new create show], path: 'audits' do
      member do
        get :status        # JSON polling fallback (mirror investment_audit_status_path)
        get :download_pdf
      end
    end
  end

  # ============================================
  # PERSONAL CABINET (A7 Phase 1 — magic-link auth)
  # ============================================
  # /cabinet — dispatch на client/staff view, требует session[:cabinet_user_id]
  # /cabinet/login — request magic-link form
  # /cabinet/verify/:token — consume token + set session
  # /cabinet/logout — delete session
  get    'cabinet',                to: 'cabinet#index',          as: :cabinet
  get    'cabinet/status.json',    to: 'cabinet#status',         as: :cabinet_status, defaults: { format: 'json' }
  get    'cabinet/login',          to: 'cabinet/auth#new',       as: :cabinet_login
  post   'cabinet/login',          to: 'cabinet/auth#create',    as: :cabinet_request_link
  get    'cabinet/verify/:token',  to: 'cabinet/auth#verify',    as: :cabinet_verify
  delete 'cabinet/logout',         to: 'cabinet/auth#destroy',   as: :cabinet_logout

  # A7 Phase 4: password reset (re-uses MagicLinkToken scope='password_reset')
  # /cabinet/password/reset       (GET)   → форма "забыли пароль" (passwords#new)
  # /cabinet/password/resets      (POST)  → отправить ссылку (passwords#create)
  # /cabinet/password/edit?token= (GET)   → форма "новый пароль" (passwords#edit)
  # /cabinet/password             (PATCH) → сохранить пароль (passwords#update)
  get    'cabinet/password/reset',   to: 'cabinet/passwords#new',    as: :new_cabinet_password
  post   'cabinet/password/resets',  to: 'cabinet/passwords#create', as: :cabinet_password_resets
  get    'cabinet/password/edit',    to: 'cabinet/passwords#edit',   as: :edit_cabinet_password
  patch  'cabinet/password',         to: 'cabinet/passwords#update', as: :cabinet_password

  # Visibility-decoupling Layer 5 — «Мои объекты» dashboard (clients
  # see their owner_user_id-linked properties с lifecycle badges).
  get    'cabinet/properties',                to: 'cabinet/properties#index',  as: :cabinet_properties
  # Self-hide / unhide — client может временно скрыть свой объект с сайта.
  post   'cabinet/properties/:id/hide',       to: 'cabinet/properties#hide',   as: :hide_cabinet_property
  post   'cabinet/properties/:id/unhide',     to: 'cabinet/properties#unhide', as: :unhide_cabinet_property

  # A7 Phase 2: избранное
  get    'cabinet/favorites',           to: 'cabinet/favorites#index',   as: :cabinet_favorites
  post   'cabinet/favorites',           to: 'cabinet/favorites#create',  as: :cabinet_create_favorite
  delete 'cabinet/favorites/:id',       to: 'cabinet/favorites#destroy', as: :cabinet_destroy_favorite

  # A7 Phase 3: digital agency contract consent
  get    'cabinet/listings/pending',     to: 'cabinet/consents#pending', as: :cabinet_pending_consents
  get    'cabinet/listings/:id/consent', to: 'cabinet/consents#show',    as: :cabinet_listing_consent
  post   'cabinet/listings/:id/consent', to: 'cabinet/consents#create',  as: :cabinet_sign_consent
  delete 'cabinet/listings/:id/consent', to: 'cabinet/consents#destroy', as: :cabinet_revoke_consent
  # Public verification (QR-target) — no auth, shows consent metadata only (no PII)
  get    'verify-contract/:token',       to: 'public_consents#show',     as: :verify_contract

  # ============================================
  # SEO LANDINGS (M1-M3 — programmatic URL pyramid)
  # ============================================
  # Generates intent × type × {district | rooms} landings with their own
  # canonical, H1, meta, and JSON-LD. Distinct from /properties so each
  # landing can rank independently in Yandex/Google. Type regex constrains
  # the slug set — anything else falls through to 404 instead of soft-404.
  LANDING_TYPE_RX = /(kvartira|dom|uchastok|komnata|kommercheskaya)/.freeze
  scope path: '/kupit', defaults: { intent: 'sale' } do
    get '/:type',                   to: 'landings#show', as: :buy_landing,           constraints: { type: LANDING_TYPE_RX }
    # Premium modifier — orthogonal axis: price >= Property::PREMIUM_THRESHOLD
    # OR is_premium=true. Phase A milestone, see strategicVector.md pillar 2.
    # Placed before more specific /:type/rayon/... to avoid 'premium' being
    # caught as a district slug.
    get '/:type/premium',           to: 'landings#show', as: :buy_premium_landing,   constraints: { type: LANDING_TYPE_RX }, defaults: { modifier: 'premium' }
    get '/:type/rayon/:district',   to: 'landings#show', as: :buy_district_landing,  constraints: { type: LANDING_TYPE_RX, district: %r{[a-z0-9-]+} }
    get '/:type/:rooms-komnatnaya', to: 'landings#show', as: :buy_rooms_landing,     constraints: { type: LANDING_TYPE_RX, rooms: /[1-4]/ }
    get '/:type/studiya',           to: 'landings#show', as: :buy_studio_landing,    constraints: { type: LANDING_TYPE_RX }, defaults: { rooms: 'studiya' }
  end
  scope path: '/snyat', defaults: { intent: 'rent' } do
    get '/:type',                   to: 'landings#show', as: :rent_landing,          constraints: { type: LANDING_TYPE_RX }
    get '/:type/rayon/:district',   to: 'landings#show', as: :rent_district_landing, constraints: { type: LANDING_TYPE_RX, district: %r{[a-z0-9-]+} }
    get '/:type/:rooms-komnatnaya', to: 'landings#show', as: :rent_rooms_landing,    constraints: { type: LANDING_TYPE_RX, rooms: /[1-4]/ }
    get '/:type/studiya',           to: 'landings#show', as: :rent_studio_landing,   constraints: { type: LANDING_TYPE_RX }, defaults: { rooms: 'studiya' }
  end

  # Phase 1.6.B — city-namespaced landings для Москвы и СПб. Рязань
  # остаётся без префикса (canonical brand). Helper format:
  # moskva_buy_landing_url(type: 'kvartira') → /moskva/kupit/kvartira
  # spb_buy_district_landing_url(type: 'kvartira', district: 'admiralteyskiy')
  #   → /spb/kupit/kvartira/rayon/admiralteyskiy
  %w[moskva spb].each do |city_slug|
    scope path: "/#{city_slug}", as: city_slug.to_sym, defaults: { city: city_slug } do
      scope path: '/kupit', defaults: { intent: 'sale' } do
        get '/:type',                   to: 'landings#show', as: :buy_landing,           constraints: { type: LANDING_TYPE_RX }
        get '/:type/premium',           to: 'landings#show', as: :buy_premium_landing,   constraints: { type: LANDING_TYPE_RX }, defaults: { modifier: 'premium' }
        get '/:type/rayon/:district',   to: 'landings#show', as: :buy_district_landing,  constraints: { type: LANDING_TYPE_RX, district: %r{[a-z0-9-]+} }
        get '/:type/:rooms-komnatnaya', to: 'landings#show', as: :buy_rooms_landing,     constraints: { type: LANDING_TYPE_RX, rooms: /[1-4]/ }
        get '/:type/studiya',           to: 'landings#show', as: :buy_studio_landing,    constraints: { type: LANDING_TYPE_RX }, defaults: { rooms: 'studiya' }
      end
      scope path: '/snyat', defaults: { intent: 'rent' } do
        get '/:type',                   to: 'landings#show', as: :rent_landing,          constraints: { type: LANDING_TYPE_RX }
        get '/:type/rayon/:district',   to: 'landings#show', as: :rent_district_landing, constraints: { type: LANDING_TYPE_RX, district: %r{[a-z0-9-]+} }
        get '/:type/:rooms-komnatnaya', to: 'landings#show', as: :rent_rooms_landing,    constraints: { type: LANDING_TYPE_RX, rooms: /[1-4]/ }
        get '/:type/studiya',           to: 'landings#show', as: :rent_studio_landing,   constraints: { type: LANDING_TYPE_RX }, defaults: { rooms: 'studiya' }
      end
    end
  end

  # ============================================
  # PROPERTIES (Каталог недвижимости)
  # ============================================
  resources :properties do
    member do
      # Favorites
      post :favorite
      delete :unfavorite

      # Viewing schedule
      post :schedule_viewing

      # Share
      get :share

      # Print version
      get :print

      # Report problem
      post :report

      # A3 — premium property dossier (5-page PDF). Premium-gated в controller;
      # 403 если property.premium? = false. Cache-friendly: ETag по
      # updated_at + images_count.
      get :dossier, defaults: { format: 'pdf' }
    end

    collection do
      # Map view
      get :map
      
      # Compare properties
      get :compare
      post :add_to_compare
      delete :remove_from_compare
      
      # Search & filters
      get :search
      get :autocomplete
    end

    # Nested resources
    resources :inquiries, only: [:new, :create]
    resources :viewings, only: [:create]
  end

  # ============================================
  # USER DASHBOARD (Личный кабинет)
  # ============================================
  namespace :dashboard do
    root 'home#index'

    # CRM-synced views
    resources :staff, only: [:index]
    resources :orders, only: %i[index show]
    resources :properties, only: [:index] do
      member do
        post :sync_from_crm
      end
    end
    resources :listings, only: [:index]

    # CRM bidirectional notes (creates Note → push to Topnlab)
    resources :notes, only: [:create]

    # Admin: register custom CRM reports + manage callbacks + reassign properties
    namespace :admin do
      resources :reports
      resources :properties, only: [:index] do
        member { patch :assign }
      end
      # Phase 7.6 — KPI dashboard для директоров (per-staff metrics + agency view)
      get :kpi, to: 'kpi#index'

      # A6 Phase 2 — admin review UI для client document intake
      resources :client_documents, only: %i[index show] do
        member do
          patch :approve
          patch :reject
        end
      end
    end

    # Profile
    resource :profile, only: [:show, :edit, :update]
    
    # Favorites
    resources :favorites, only: [:index, :destroy] do
      collection do
        delete :clear_all
        get :export
      end
    end
    
    # My inquiries
    resources :inquiries, only: [:index, :show, :destroy] do
      member do
        post :cancel
        get :timeline
      end
    end
    
    # Saved searches
    resources :saved_searches do
      member do
        post :activate
        post :deactivate
        post :check_new
      end
    end
    
    # Messages
    resources :messages, only: [:index, :show, :create] do
      collection do
        get :unread
        post :mark_all_read
      end
      member do
        post :mark_read
      end
    end
    
    # Notifications
    resources :notifications, only: [:index] do
      collection do
        post :mark_all_read
        delete :clear_all
      end
      member do
        post :mark_read
      end
    end
    
    # Settings
    resource :settings, only: [:show, :update] do
      get :notifications, action: :notification_settings
      patch :notifications, action: :update_notification_settings
      delete :account, action: :destroy_account
    end
    
    # Viewing history
    resources :history, only: [:index] do
      collection do
        delete :clear
      end
    end
    
    # Property comparison
    resources :comparisons, only: [:index, :destroy] do
      collection do
        delete :clear_all
      end
    end
  end

  # ============================================
  # SELL PROPERTY (Продать недвижимость)
  # ============================================
  namespace :sell do
    root 'evaluations#new', as: :root

    # Property evaluation
    resource :evaluation, only: [:new, :create, :show] do
      get :result, on: :member
    end
    
    # List property
    resources :listings, only: [:new, :create, :edit, :update] do
      member do
        get :preview
        post :publish
        post :unpublish
      end
    end
    
    # Pricing plans
    resources :plans, only: [:index, :show]
  end

  # ============================================
  # PROPERTY VALUATIONS (Онлайн-оценка недвижимости)
  # ============================================
  # Phase 4 — mode-picker landing: Express ('сколько стоит') vs
  # Investment Audit ('стоит ли покупать?'). Replaces the pre-Phase-4
  # blind redirect to /valuations/new.
  get '/valuations', to: 'valuations#index', as: :valuations

  resources :property_valuations, path: 'valuations', only: [:new, :create] do
    collection do
      get ':token/result', to: 'property_valuations#result', as: :result
      get ':token/status', to: 'property_valuations#status', as: :status # async loader polling
      get ':token/download', to: 'property_valuations#download_pdf', as: :download_pdf
      post ':token/request_call', to: 'property_valuations#request_call', as: :request_call
    end
  end

  # ============================================
  # INVESTMENT AUDIT — Phase 4 (audit-engine-v2 sidecar)
  # ============================================
  # New flow for buyers/investors: "stoit li pokupat'?" Calls the
  # FastAPI sidecar for EI/Monte Carlo/PDF. Token-based, no auth required
  # for the public form (visitor_token-based rate limiting in controller).
  scope path: '/valuations/audit', as: :investment_audit do
    get  '/new',          to: 'valuations/investment#new',         as: :new
    post '/',             to: 'valuations/investment#create',      as: :create
    get  '/:token',       to: 'valuations/investment#show',        as: :show
    get  '/:token/pdf',   to: 'valuations/investment#download_pdf', as: :pdf
    get  '/:token/status', to: 'valuations/investment#status',      as: :status  # polling fallback
  end

  # ============================================
  # SERVICES (Сервисы)
  # ============================================
  namespace :services do
    # Финансы — 4 страницы раздела. Раньше всё было на одном
    # /services/mortgage_calculator; теперь разделено на отдельные URL'ы
    # для лучшей навигации и SEO.

    # 1. Ипотечный калькулятор + программы ипотеки
    resource :mortgage, only: [:show], controller: 'mortgage_calculators' do
      post :calculate
      get :banks
      get :programs
    end

    # 2. Депозитный калькулятор + программы вкладов
    resource :deposit, only: [:show], controller: 'deposit_calculators'

    # 3. Сравнение «вклад vs ипотека» — интерактивный калькулятор
    get 'mortgage_vs_deposit', to: 'finance_compare#show', as: :mortgage_vs_deposit

    # Back-compat alias — старый URL `/services/mortgage_calculator`
    # уже проиндексирован Яндексом / Google, в чатботе, в письмах.
    # 301 redirect передаёт SEO-вес на новую страницу.
    get 'mortgage_calculator',          to: redirect('/services/mortgage', status: 301)
    get 'mortgage_calculator/programs', to: redirect('/services/mortgage', status: 301)
    get 'mortgage_calculator/banks',    to: redirect('/services/mortgage', status: 301)

    # 4. Заявка на ипотеку (без изменений)
    resources :mortgage_applications, only: [:new, :create, :show] do
      member do
        get :status
      end
    end

    # Per-program application entry (cross-link from audit result page).
    # `:id` is the bank-offer UUID from audit-engine; controller resolves it
    # via Mortgage::ProgramsService.find and prefills the form.
    get 'mortgage/programs/:id/apply',
        to: 'mortgage_applications#new',
        as: :mortgage_program_apply
    
    # Legal services
    resources :legal_services, only: [:index, :show] do
      member do
        post :request_service, path: 'request'
      end
    end

    # Document assistance
    resources :document_services, only: [:index] do
      collection do
        post :request_service, path: 'request'
      end
    end
    
    # Virtual tours
    resources :virtual_tours, only: [:index, :show] do
      collection do
        get :featured
      end
    end
  end

  # ============================================
  # FORMS & INTERACTIONS (Формы)
  # ============================================
  namespace :forms do
    # Quick inquiry
    resource :quick_inquiry, only: [:create]
    
    # Viewing schedule
    resource :viewing_request, only: [:create]
    
    # Mortgage request
    resource :mortgage_request, only: [:create]
    
    # Online consultation
    resource :consultation_request, only: [:create]
    
    # Callback request
    resource :callback_request, only: [:create]
    
    # Contact agent
    resource :agent_contact, only: [:create]

    # Generic service request (from /services page modal)
    resource :service_request, only: [:create]
  end

  # ============================================
  # CONTACT FORMS (NEW - Формы обратной связи)
  # ============================================
  namespace :contact_forms do
    post :quick_inquiry
    post :viewing_schedule
    post :callback
    post :consultation
    post :mortgage_application
    post :property_selection
  end

  # ============================================
  # CHAT & MESSAGING
  # ============================================
  namespace :chat do
    # Public widget — singleton conversation per visitor (cookie-identified)
    resource :conversation, only: %i[show update], controller: 'conversations' do
      resources :messages, only: %i[create], controller: '/chat/messages'
    end

    # Legacy User↔User chat (kept for future internal messaging)
    resources :conversations, only: [:index] do
      resources :messages, only: [:create]
    end

    # Online status
    post 'online', to: 'presence#online'
    post 'offline', to: 'presence#offline'
  end
  
  # Chatbot
  namespace :chatbot do
    post 'message', to: 'messages#create'
    get 'suggestions', to: 'messages#suggestions'
  end

  # ============================================
  # ACTIONCABLE (WebSockets for real-time chat)
  # ============================================
  mount ActionCable.server => '/cable'

  # ============================================
  # STATIC PAGES
  # ============================================
  # About
  get 'about', to: 'pages#about', as: :about
  get 'about/team', to: 'pages#team', as: :team
  get 'about/history', to: 'pages#history', as: :history

  # Public agent profile pages (B3 — Person Schema + E-E-A-T)
  get 'agents/:slug', to: 'agents#show', as: :agent, constraints: { slug: %r{[a-z0-9-]+} }
  
  # Contacts
  get 'contacts', to: 'pages#contacts', as: :contacts
  post 'contacts', to: 'pages#send_contact_form', as: :send_contact_form

  # ============================================
  # PREMIUM SEGMENT (Phase A1)
  # ============================================
  # Standalone brand-statement landing. Отличается от SEO district
  # pyramid /buy/:type/premium — там per-type, здесь общий обзор.
  get 'premium', to: 'premium#index', as: :premium
  
  # Services
  get 'services', to: 'pages#services', as: :services_page
  
  # FAQ
  get 'faq', to: 'pages#faq', as: :faq
  
  # Privacy & Terms
  get 'privacy', to: 'pages#privacy', as: :privacy
  get 'terms', to: 'pages#terms', as: :terms
  
  # Blog
  get 'blog', to: 'blog#index', as: :blog
  get 'blog/:slug', to: 'blog#show', as: :blog_post
  get 'blog/category/:category', to: 'blog#category', as: :blog_category
  
  # News
  get 'news', to: 'news#index', as: :news
  get 'news/:id', to: 'news#show', as: :news_item

  # ============================================
  # CASE STUDIES (Pillar 2 — закрытые сделки)
  # ============================================
  # URL остаётся /cases/:slug для пользователя, внутри модель CaseStudy
  # (не Case — overlap с Ruby keyword). resources помечен path: 'cases',
  # as: :cases — helpers cases_path / case_path(@case_study) выглядят
  # естественно.
  resources :case_studies, only: %i[index show], path: 'cases', as: :cases, param: :slug

  # ============================================
  # EXTERNAL LISTINGS (Phase 2 MLS/YRL)
  # ============================================
  # Показ чужих объявлений (из ExternalListing) на нашем сайте с lead-capture
  # формой. Detail page имеет rel="canonical" → наша же страница (НЕ external
  # URL — не leak'ить трафик). Lead через нашу форму → Inquiry с
  # external_listing_id, дальше Phase 3 routing к partner agency с комиссией.
  resources :external_listings, only: %i[show], path: 'external-listings'

  # ============================================
  # PARTNERS PORTAL (Phase 3b MLS/YRL)
  # ============================================
  # Magic-link auth → dashboard with read-only view of own referrals.
  # Separate session key (session[:partner_agency_id]) from cabinet_user_id.
  get    'partners/login',         to: 'partners/auth#new',       as: :partners_login
  post   'partners/login',         to: 'partners/auth#create',    as: :partners_request_link
  get    'partners/verify/:token', to: 'partners/auth#verify',    as: :partners_verify
  delete 'partners/logout',        to: 'partners/auth#destroy',   as: :partners_logout
  get    'partners',               to: 'partners/dashboard#index', as: :partners

  # ============================================
  # REVIEWS
  # ============================================
  resources :reviews, only: [:index, :new, :create] do
    member do
      post :helpful
    end
  end

  # ============================================
  # ADMIN — review moderation
  # ============================================
  # Token-based auth (ENV['ADMIN_TOKEN']) until Devise comes back online.
  # See Admin::ReviewsController#require_admin_token.
  namespace :admin do
    # Token-cookie login flow (AdminTokenAuth concern). Lets ops paste the
    # ENV['ADMIN_TOKEN'] once on /admin/login, then navigate without dragging
    # it through every URL.
    get  'login',  to: 'sessions#new',     as: :login
    post 'login',  to: 'sessions#create'
    delete 'logout', to: 'sessions#destroy', as: :logout

    root to: 'dashboard#index'

    resources :reviews, only: %i[index show] do
      member do
        post :approve
        post :reject
      end
    end

    # Phase 11 Iter 30 — operational health JSON для oncall / monitoring.
    get :health, to: 'health#show'

    # Article moderation + manual creation. Token-guarded via AdminTokenAuth.
    resources :articles do
      member do
        post :hide
        post :unhide
        post :publish
        post :publish_to_telegram
      end
    end

    # Case studies — анонимизированные кейсы по закрытым сделкам (Pillar 2).
    # Token-guarded через AdminTokenAuth. Public mapping ниже (resources
    # :case_studies path: 'cases') — публичный URL /cases/:slug.
    resources :case_studies, except: :show do
      member do
        post :publish
        post :archive
        post :soft_delete
      end
    end

    # SEO landing content CRUD — edit district/type landing copy from the
    # panel. Each row is rendered by LandingsController#show in preference
    # to the file-backed ERB partials, so changes are live immediately
    # (no deploy required).
    resources :landing_contents do
      member do
        post :publish
        post :unpublish
      end
      collection do
        post :upload_image
      end
    end

    # Property publication dashboard — shows the result of the
    # ready_for_site? gate for every CRM-synced Property, plus the
    # force_publish override toggle. Lets admins fix "missing from
    # catalog" cases without touching CRM.
    resources :properties, only: %i[index] do
      member do
        post :toggle_force_publish
        post :toggle_force_archive   # Visibility-decoupling Layer 4
        # A7 Phase 3 — request signature from client (digital agency contract)
        get  :request_consent
        post :send_consent_request
      end
    end

    # Topnlab sync health dashboard — recent runs + counts.
    get 'topnlab_status', to: 'topnlab_status#index', as: :topnlab_status

    # Bank-rates scraper dashboard — last snapshot + diff vs previous.
    get  'bank_rates',         to: 'bank_rates#index',   as: :bank_rates
    post 'bank_rates/refresh', to: 'bank_rates#refresh', as: :refresh_bank_rates

    # Phase 3 MLS/YRL — referral lifecycle management.
    resources :referrals, only: %i[index show] do
      member do
        post :forward
        post :close_won
        post :close_lost
      end
      collection do
        get :settlements
      end
    end
  end

  # ============================================
  # API v1
  # ============================================
  namespace :api do
    namespace :v1 do
      # Address autocomplete (Phase 4.6): DaData-proxied suggestions for
      # the audit/express forms. Server-side caches results 7d in Redis.
      get 'addresses/autocomplete', to: 'addresses#autocomplete'

      # Authentication
      post 'auth/login', to: 'authentication#login'
      post 'auth/logout', to: 'authentication#logout'
      post 'auth/refresh', to: 'authentication#refresh'
      
      # Properties
      resources :properties, only: [:index, :show] do
        collection do
          get :search
          get :featured
          get :recent
        end
        
        member do
          get :similar
        end
      end
      
      # User
      resource :profile, only: [:show, :update]
      
      # Favorites
      resources :favorites, only: [:index, :create, :destroy]
      
      # Inquiries
      resources :inquiries, only: [:index, :create, :show]
      
      # Saved searches
      resources :saved_searches, only: [:index, :create, :destroy, :update]
      
      # Mortgage calculator
      post 'mortgage_calculator/calculate', to: 'mortgage_calculator#calculate'
      
      # Property evaluation
      post 'property_evaluation', to: 'property_evaluation#create'
      
      # Recommendations
      get 'recommendations', to: 'recommendations#index'
      
      # Stats
      get 'stats', to: 'stats#index'
    end
  end

  # ============================================
  # WEBHOOKS
  # ============================================
  namespace :webhooks do
    # AmoCRM
    post 'amocrm', to: 'amocrm#create'

    # News ingest from chat-host cron (urgent / digest pipelines).
    # Bearer-auth via ENV[NEWS_INGEST_TOKEN]. See services/chat-host-cron/.
    post 'news_ingest', to: 'news_ingest#create', as: :news_ingest

    # Telegram
    post 'telegram', to: 'telegram#create'

    # Payment systems
    post 'yookassa', to: 'yookassa#create'

    # Topnlab CRM — card create/edit notifications
    post 'topnlab', to: 'topnlab#create'

    # Topnlab Reports API callback — generates PDF for selected ids on demand
    post 'topnlab/reports/:slug', to: 'topnlab_reports#create', as: :topnlab_report
  end

  # ============================================
  # SITEMAP & SEO
  # ============================================
  # Sitemap-index pattern: /sitemap.xml — корневой index, ссылается на 3
  # sub-sitemap'a по crawl-частоте (pages/listings/blog) + news. Я.Вебмастер
  # лучше работает с index-схемой: один URL в Webmaster settings, sub-sitemaps
  # независимо tracked и обновляются. Готовит почву для Phase 1.6 multi-city,
  # где sub-sitemaps можно будет per-city разрезать.
  get 'sitemap.xml',          to: 'sitemap#index',    defaults: { format: 'xml' }
  get 'sitemap-pages.xml',    to: 'sitemap#pages',    defaults: { format: 'xml' }
  get 'sitemap-listings.xml', to: 'sitemap#listings', defaults: { format: 'xml' }
  get 'sitemap-blog.xml',     to: 'sitemap#blog',     defaults: { format: 'xml' }
  # Google News sitemap (separate from main sitemap.xml — different schema,
  # different lastmod expectations, only articles ≤ 2 days old are eligible).
  get 'sitemap-news.xml', to: 'sitemap#news', defaults: { format: 'xml' }
  get 'robots.txt', to: 'robots#index', defaults: { format: 'txt' }
  # IndexNow ownership-proof file at /<key>.txt — Bing/Yandex/Brave/Yep/Naver
  # fetch this to verify we own ENV['INDEXNOW_API_KEY'] before accepting
  # push notifications via Seo::IndexNowNotifier.
  get ':key.txt',
      to:          'index_now_key#show',
      constraints: { key: /[a-fA-F0-9]{8,128}/ },
      defaults:    { format: 'txt' },
      as:          :index_now_key

  # Aggregator feeds (Yandex.Недвижимость / ЦИАН / Авито / МирКвартир /
  # Restate / Domofond). Three native formats — each aggregator has its own
  # XSD. YRL acts as fallback for МирКвартир/Restate/Domofond.
  get 'feeds/yrl.xml',   to: 'feeds#yrl',   defaults: { format: 'xml' }, as: :yrl_feed
  get 'feeds/cian.xml',  to: 'feeds#cian',  defaults: { format: 'xml' }, as: :cian_feed
  get 'feeds/avito.xml', to: 'feeds#avito', defaults: { format: 'xml' }, as: :avito_feed

  # ============================================
  # PWA
  # ============================================
  get 'manifest.json', to: 'pwa#manifest', defaults: { format: 'json' }
  get 'service-worker.js', to: 'pwa#service_worker', defaults: { format: 'js' }
  get 'offline', to: 'pwa#offline'

  # ============================================
  # HEALTH CHECK & MONITORING
  # ============================================
  get 'health', to: 'health#index'
  get 'health/database', to: 'health#database'
  get 'health/redis', to: 'health#redis'
  get 'health/sidekiq', to: 'health#sidekiq'

  # ============================================
  # ERRORS
  # ============================================
  match '/404', to: 'errors#not_found', via: :all
  match '/422', to: 'errors#unprocessable_entity', via: :all
  match '/500', to: 'errors#internal_server_error', via: :all

  # Catch-all for any path that didn't match a real route above. Renders the
  # branded 404 instead of Rails' debug page in development or the bare
  # public/404.html fallback in production. Must remain the LAST route in the
  # file — anything below it will be unreachable.
  match '*unmatched',
        to: 'errors#not_found',
        via: :all,
        constraints: ->(req) { !req.path.start_with?('/rails/', '/cable', '/assets/') }

  # ============================================
  # DEVELOPMENT TOOLS (only in development) - Temporarily disabled
  # ============================================
  # if Rails.env.development?
  #   # Letter Opener
  #   mount LetterOpenerWeb::Engine, at: '/letter_opener'
  #   
  #   # Sidekiq Web UI
  #   require 'sidekiq/web'
  #   mount Sidekiq::Web => '/sidekiq'
  #   
  #   # Flipper UI (Feature Flags)
  #   mount Flipper::UI.app(Flipper) => '/flipper'
  # end
end