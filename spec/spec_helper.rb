# frozen_string_literal: true

# RSpec Configuration for АН "Виктори"

RSpec.configure do |config|
  # rspec-expectations config
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # rspec-mocks config
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  # This option will default to `:apply_to_host_groups` in RSpec 4
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Run specs in random order to surface order dependencies
  config.order = :random

  # Seed global randomization
  Kernel.srand config.seed

  # Allow more verbose output when running an individual spec file
  if config.files_to_run.one?
    config.default_formatter = "doc"
  end

  # Print the 10 slowest examples and example groups
  config.profile_examples = 10

  # Disable monkey patching (recommended)
  config.disable_monkey_patching!

  # Warnings
  config.warnings = false
end

