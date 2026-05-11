# frozen_string_literal: true

module ChatTools
  # Build public listing URLs that work both inside a request and from
  # background jobs / console (no Rails URL helpers needed).
  module Url
    module_function

    def property_path(slug)
      "/properties/#{slug}"
    end

    def investment_audit_path(token)
      "/valuations/audit/#{token}"
    end
  end
end
