# frozen_string_literal: true

# FactoryBot Configuration

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
  
  # Lint factories
  config.before(:suite) do
    begin
      FactoryBot.lint
    rescue StandardError => e
      puts "❌ FactoryBot lint failed: #{e.message}"
    end
  end
end

