# frozen_string_literal: true

module Webhooks
  # Receives Topnlab POSTs when an agent in CRM clicks "Сформировать отчёт"
  # on a registered custom report. Generates PDF synchronously and returns
  # `{url: ...}` per the Reports API contract.
  class TopnlabReportsController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    TIMEOUT_BUFFER = 8 # CRM waits up to 10s; leave headroom for network.

    def create
      report = CrmReport.find_by!(slug: params[:slug])
      payload = parsed_payload

      # Defense-in-depth: template_class уже ограничен модельной валидацией
      # (CrmReport: inclusion in TEMPLATE_CLASSES), но явный allowlist-guard на
      # call-site закрывает constantize-RCE даже если запись попала в БД в обход
      # валидации (raw SQL / seed). Brakeman UnsafeReflection — clean.
      name = report.template_class
      unless CrmReport::TEMPLATE_CLASSES.include?(name)
        raise ArgumentError, "Unregistered template_class: #{name}"
      end

      file_url = Timeout.timeout(TIMEOUT_BUFFER) do
        klass = name.constantize
        klass.new(ids: payload['ids'], user: payload['user'], report: report).generate_and_upload!
      end

      response.set_header('Access-Control-Allow-Origin', '*')
      response.set_header('Access-Control-Allow-Headers', '*')
      render json: { url: file_url }
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Report '#{params[:slug]}' not registered" }, status: :not_found
    rescue Timeout::Error
      Rails.logger.error("[Reports] timeout generating #{params[:slug]} for ids=#{params[:ids]}")
      render json: { error: 'Generation timed out' }, status: :request_timeout
    rescue StandardError => e
      Rails.logger.error("[Reports] failed for #{params[:slug]}: #{e.class} #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def parsed_payload
      raw = request.body.read
      return JSON.parse(raw) if raw.present?
      params.to_unsafe_h.stringify_keys
    rescue JSON::ParserError
      params.to_unsafe_h.stringify_keys
    end
  end
end
