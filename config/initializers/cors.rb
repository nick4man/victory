# frozen_string_literal: true

# CORS Configuration
# Configure Cross-Origin Resource Sharing (CORS) for API requests

# Uncomment if you need to enable CORS for external API access
# This is already configured in application.rb, but you can customize it here

# Rails.application.config.middleware.insert_before 0, Rack::Cors do
#   # Allow API requests from specific origins
#   allow do
#     origins ENV.fetch('CORS_ORIGINS', '*').split(',')
#     
#     resource '/api/*',
#       headers: :any,
#       methods: [:get, :post, :put, :patch, :delete, :options, :head],
#       credentials: false,
#       max_age: 600
#   end
#   
#   # Allow ActionCable connections
#   allow do
#     origins ENV.fetch('CORS_ORIGINS', '*').split(',')
#     
#     resource '/cable',
#       headers: :any,
#       methods: [:get, :post, :options],
#       credentials: true
#   end
# end

