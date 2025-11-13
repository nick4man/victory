# frozen_string_literal: true

# Request Helpers for RSpec

module RequestHelpers
  # Parse JSON response
  def json_response
    JSON.parse(response.body)
  end

  # Authentication helpers
  def auth_headers(user)
    token = user.generate_jwt_token
    { 'Authorization' => "Bearer #{token}" }
  end

  def authenticated_request(method, path, user, params: {}, headers: {})
    send(method, path, params: params, headers: auth_headers(user).merge(headers))
  end

  # Common expectations
  def expect_success_response
    expect(response).to have_http_status(:success)
  end

  def expect_created_response
    expect(response).to have_http_status(:created)
  end

  def expect_unauthorized_response
    expect(response).to have_http_status(:unauthorized)
  end

  def expect_not_found_response
    expect(response).to have_http_status(:not_found)
  end

  def expect_unprocessable_entity_response
    expect(response).to have_http_status(:unprocessable_entity)
  end

  # JSON structure expectations
  def expect_json_keys(*keys)
    keys.each do |key|
      expect(json_response).to have_key(key.to_s)
    end
  end
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
end

