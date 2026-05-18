# frozen_string_literal: true

# Be sure to restart your server when you modify this file.
#
# DLP — никогда не log'аем sensitive fields в plain text.
#
# Rails автоматически фильтрует params matching эти keys в логах
# (например, /var/log/rails/production.log не содержит passport_number).
# Также применяется к Inquiry.metadata, ClientDocument.parsed_data
# когда они printed как hash. См. ActiveSupport::ParameterFilter docs.
#
# Categories:
#   - auth: password, token, secret
#   - PII (152-ФЗ): паспорт, СНИЛС, ИНН, дата рождения, full FIO + adres
#   - financial: банковские реквизиты, card data
#   - third-party: API keys из webhook payloads
Rails.application.config.filter_parameters += %i[
  password
  password_confirmation
  secret
  token
  authentication_token
  api_key

  passport_number
  passport_series
  passport_data
  inn
  snils
  birth_date
  issued_by

  card_number
  cvv
  iban
  bik

  yandex_vision_response
  parsed_data
  ocr_raw_text

  # Yandex.Webmaster OAuth — user-scope token, отзываемый, но всё равно
  # секретный (доступ к private webmaster data + user identity).
  yandex_webmaster_token
  oauth_token
  access_token
  refresh_token
  authorization

  # Iter 1.5 — добавили phone/email/message чтобы Rails-уровень логирования
  # «Processing by FormsController» не печатал raw value'ы. Trade-off:
  # cabinet/login email тоже маскируется, но это меньшая боль чем PII leak
  # (152-ФЗ + log retention compliance). Если нужен debug — Rails.logger
  # tagged + explicit hash.
  phone
  email
  message
  comment
  identifier
  full_name
]
