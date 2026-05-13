# frozen_string_literal: true

# Serves the IndexNow ownership-proof file at /<key>.txt with `key` matching
# ENV['INDEXNOW_API_KEY']. Search engines (Bing, Yandex, Brave, Naver, etc.)
# fetch this URL to verify the site owns the key before accepting IndexNow
# notifications.
#
# Route (config/routes.rb):
#   get ':key.txt', to: 'index_now_key#show',
#       constraints: { key: /[a-fA-F0-9]{8,128}/ },
#       defaults:    { format: 'txt' }
#
# Setup: see .claude/docs/seo/indexnow-setup.md
class IndexNowKeyController < ApplicationController
  # Public endpoint — no auth, no CSRF token (search engines call it cold).
  skip_before_action :verify_authenticity_token, raise: false

  def show
    api_key = ENV['INDEXNOW_API_KEY']
    requested_key = params[:key].to_s

    if api_key.present? && ActiveSupport::SecurityUtils.secure_compare(requested_key, api_key)
      render plain: api_key, content_type: 'text/plain'
    else
      head :not_found
    end
  end
end
