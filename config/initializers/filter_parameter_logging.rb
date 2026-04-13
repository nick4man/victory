# frozen_string_literal: true

# Скрывать из логов чувствительные параметры.
# Значения заменяются на "[FILTERED]".
Rails.application.config.filter_parameters += %i[
  password
  password_confirmation
  current_password
  secret
  token
  _token
  authenticity_token
  credit_card_number
  cvv
  ssn
  passphrase
  otp
  api_key
  access_token
  refresh_token
  jwt
  authorization
  cookie
]
