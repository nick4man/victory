# frozen_string_literal: true

# Kaminari Configuration
# Pagination settings

Kaminari.configure do |config|
  # Default number of items per page
  config.default_per_page = 20
  
  # Maximum number of items per page
  config.max_per_page = 100
  
  # Default number of pagination links
  config.window = 2
  
  # Number of links on the left/right edges
  config.outer_window = 1
  
  # Left/right delimiters
  config.left = 2
  config.right = 2
  
  # Parameter name for page number
  config.page_method_name = :page
  
  # Parameter name for per-page number
  config.param_name = :page
  
  # Maximum pages for pager
  config.max_pages = nil
  
  # Params on first page
  config.params_on_first_page = false
end

