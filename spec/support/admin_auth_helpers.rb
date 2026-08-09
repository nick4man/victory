# frozen_string_literal: true

# Хелперы для request-спеков админки (первый такой спек появился 09.08.26).
#
# Devise отключён; доступ даёт AdminTokenAuth по `ENV['ADMIN_TOKEN']` —
# либо `?token=` в запросе, либо дайджест в session-cookie после
# /admin/login. В спеках используем первый путь: он же засевает cookie,
# поэтому следующие запросы внутри примера авторизованы и без параметра.
#
# ENV подменяется around-блоком с восстановлением — по образцу
# spec/requests/webhooks/topnlab_controller_spec.rb.
module AdminAuthHelpers
  ADMIN_TEST_TOKEN = 'test-admin-token-9f3a'

  def admin_token
    ADMIN_TEST_TOKEN
  end

  def admin_get(path, params: {}, **opts)
    get path, params: params.merge(token: ADMIN_TEST_TOKEN), **opts
  end

  def admin_post(path, params: {}, **opts)
    post path, params: params.merge(token: ADMIN_TEST_TOKEN), **opts
  end

  def admin_patch(path, params: {}, **opts)
    patch path, params: params.merge(token: ADMIN_TEST_TOKEN), **opts
  end
end

# Подключается явно (`include_context 'с админ-токеном'`), а не глобально:
# не-админские request-спеки не должны видеть выставленный ADMIN_TOKEN.
RSpec.shared_context 'с админ-токеном' do
  around do |example|
    original = ENV.fetch('ADMIN_TOKEN', nil)
    ENV['ADMIN_TOKEN'] = AdminAuthHelpers::ADMIN_TEST_TOKEN
    example.run
    ENV['ADMIN_TOKEN'] = original
  end
end

RSpec.configure do |config|
  config.include AdminAuthHelpers, type: :request
end
