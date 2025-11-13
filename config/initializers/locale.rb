# frozen_string_literal: true

# Locale Configuration for АН "Виктори"

# Set default locale to Russian
I18n.default_locale = :ru

# Available locales
I18n.available_locales = [:ru, :en]

# Load locale files from subdirectories
I18n.load_path += Dir[Rails.root.join('config', 'locales', '**', '*.{rb,yml}')]

# Enforce available locales
I18n.enforce_available_locales = true

# Fallback to default locale
I18n.fallbacks = [:ru, :en]

