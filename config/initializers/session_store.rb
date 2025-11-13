# frozen_string_literal: true

# Session Store Configuration

# Use cookie store for all environments (simpler and works out of the box)
# Redis session store requires additional gems
Rails.application.config.session_store :cookie_store,
  key: '_viktory_realty_session',
  expire_after: ENV.fetch('SESSION_TIMEOUT', 1800).to_i.seconds,
  secure: Rails.env.production?,
  httponly: true,
  same_site: :lax

