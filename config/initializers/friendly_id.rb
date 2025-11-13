# frozen_string_literal: true

# FriendlyId Configuration
# Generates SEO-friendly URLs (slugs)

FriendlyId.defaults do |config|
  # Reserved words (removed - not supported in FriendlyId 5.5+)
  # Use :reserved module in models instead
  # config.reserved_words = %w[new edit index session login logout users admin
  #   stylesheets assets javascripts images api properties dashboard]

  # Use this to set the default status for finding slugs
  # config.base = :name

  # Whether to use the simple form of friendly_id: `friendly_id :title`
  config.use :slugged

  # Available slug generators: :parameterize (default), :transliterate, :russian
  # :parameterize will turn "Moscow City" to "moscow-city"
  config.slug_generator_class = FriendlyId::SlugGenerator

  # Configuration for finding records
  config.sequence_separator = '-'

  # Additional modules
  # :history - keeps track of changed slugs
  # :reserved - prevents use of reserved words (use in models)
  # :scoped - allows duplicate slugs for different scopes
  # :finders - allows finding by slug or id
end

