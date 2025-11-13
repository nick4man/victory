# frozen_string_literal: true

# АН "Виктори" - Routes Configuration
# Digital Platform for Real Estate Agency

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # ============================================
  # ADMIN PANEL (ActiveAdmin) - Temporarily disabled
  # ============================================
  # devise_for :admin_users, ActiveAdmin::Devise.config
  # ActiveAdmin.routes(self)

  # ============================================
  # USER AUTHENTICATION (Devise) - Temporarily disabled
  # ============================================
  # devise_for :users, controllers: {
  #   registrations: 'users/registrations',
  #   sessions: 'users/sessions',
  #   passwords: 'users/passwords',
  #   omniauth_callbacks: 'users/omniauth_callbacks'
  # }

  # ============================================
  # MAIN ROUTES
  # ============================================
  
  # Homepage (using minimal landing page for design work)
  root 'landing#index'

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
  resources :property_valuations, path: 'valuations', only: [:new, :create] do
    collection do
      get ':token/result', to: 'property_valuations#result', as: :result
      get ':token/download', to: 'property_valuations#download_pdf', as: :download_pdf
      post ':token/request_call', to: 'property_valuations#request_call', as: :request_call
    end
  end

  # ============================================
  # SERVICES (Сервисы)
  # ============================================
  namespace :services do
    # Mortgage calculator
    resource :mortgage_calculator, only: [:show] do
      post :calculate
      get :banks
      get :programs
    end
    
    # Mortgage application
    resources :mortgage_applications, only: [:new, :create, :show] do
      member do
        get :status
      end
    end
    
    # Legal services
    resources :legal_services, only: [:index, :show] do
      member do
        post :request
      end
    end
    
    # Document assistance
    resources :document_services, only: [:index] do
      collection do
        post :request
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
    resources :conversations, only: [:index, :show, :create] do
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
  
  # Contacts
  get 'contacts', to: 'pages#contacts', as: :contacts
  post 'contacts', to: 'pages#send_contact_form'
  
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
  # REVIEWS
  # ============================================
  resources :reviews, only: [:index, :create] do
    member do
      post :helpful
    end
  end

  # ============================================
  # API v1
  # ============================================
  namespace :api do
    namespace :v1 do
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
    
    # Telegram
    post 'telegram', to: 'telegram#create'
    
    # Payment systems
    post 'yookassa', to: 'yookassa#create'
  end

  # ============================================
  # SITEMAP & SEO
  # ============================================
  get 'sitemap.xml', to: 'sitemap#index', defaults: { format: 'xml' }
  get 'robots.txt', to: 'robots#index', defaults: { format: 'txt' }

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