# frozen_string_literal: true

# MetaTags Configuration
# SEO meta tags defaults

MetaTags.configure do |config|
  # Default settings
  config.title_limit        = 70
  config.description_limit  = 300
  config.keywords_limit     = 255
  config.keywords_separator = ', '
  
  # Default title (removed - not supported in meta-tags 2.20)
  # config.site_name = 'АН "Виктори"'
  # config.separator = ' | '
  
  # Open Graph defaults (removed - not supported in meta-tags 2.20)
  # config.open_graph = {
  #   site_name: 'АН "Виктори"',
  #   type: 'website',
  #   locale: 'ru_RU'
  # }
  
  # Twitter Card defaults (removed - not supported in meta-tags 2.20)
  # config.twitter = {
  #   card: 'summary_large_image',
  #   site: '@viktory_realty'
  # }
end

