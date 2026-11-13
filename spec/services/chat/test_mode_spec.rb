# frozen_string_literal: true

require 'rails_helper'

# Политика тест-изоляции лидов чат-бота (issue #227) — app/services/chat/test_mode.rb.
RSpec.describe Chat::TestMode do
  describe '.force_test?' do
    around do |example|
      old = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
      example.run
      old.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old
    end

    it "'1' — кран открыт, иное значение/отсутствие — закрыт" do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      expect(described_class.force_test?).to be(true)

      ENV['SITE_CHATBOT_FORCE_TEST'] = 'true'
      expect(described_class.force_test?).to be(false)

      ENV.delete('SITE_CHATBOT_FORCE_TEST')
      expect(described_class.force_test?).to be(false)
    end
  end

  describe '.site_source?' do
    it 'site-источники Lead::Intake — да, прочие — нет' do
      expect(described_class.site_source?('site_form')).to be(true)
      expect(described_class.site_source?('site_valuation')).to be(true)
      expect(described_class.site_source?('site_mortgage')).to be(true)
      expect(described_class.site_source?('tg_dm')).to be(false)
      expect(described_class.site_source?('manual')).to be(false)
      expect(described_class.site_source?('crm_webhook')).to be(false)
    end
  end

  describe '.prod_host? / .auto_test_request?' do
    # Детерминизм: окружение спеки не должно зависеть от ENV хоста прогона.
    around do |example|
      old_ips  = ENV.fetch('SITE_CHATBOT_OFFICE_IPS', nil)
      old_prod = ENV.fetch('SITE_CHATBOT_PROD_HOSTS', nil)
      ENV.delete('SITE_CHATBOT_OFFICE_IPS')
      ENV.delete('SITE_CHATBOT_PROD_HOSTS')
      example.run
      old_ips.nil? ? ENV.delete('SITE_CHATBOT_OFFICE_IPS') : ENV['SITE_CHATBOT_OFFICE_IPS'] = old_ips
      old_prod.nil? ? ENV.delete('SITE_CHATBOT_PROD_HOSTS') : ENV['SITE_CHATBOT_PROD_HOSTS'] = old_prod
    end

    def request_double(host:, remote_ip: '203.0.113.10')
      instance_double(ActionDispatch::Request, host: host, remote_ip: remote_ip)
    end

    it 'прод-домены (с/без www, регистр, порт) — прод' do
      expect(described_class.prod_host?('victory62.org')).to be(true)
      expect(described_class.prod_host?('www.victory62.org')).to be(true)
      expect(described_class.prod_host?('WWW.Victory62.org')).to be(true)
      expect(described_class.prod_host?('victory62.org:443')).to be(true)
    end

    it 'staging/localhost/произвольный хост — не прод' do
      expect(described_class.prod_host?('staging.victory62.org')).to be(false)
      expect(described_class.prod_host?('localhost')).to be(false)
      expect(described_class.prod_host?('127.0.0.1')).to be(false)
    end

    it 'auto_test_request: staging и localhost → true' do
      expect(described_class.auto_test_request?(request_double(host: 'staging.victory62.org'))).to be(true)
      expect(described_class.auto_test_request?(request_double(host: 'localhost'))).to be(true)
    end

    it 'auto_test_request: прод-хост → false' do
      expect(described_class.auto_test_request?(request_double(host: 'victory62.org'))).to be(false)
    end

    it 'прод-хост + офисный IP → true (IP перевешивает)' do
      ENV['SITE_CHATBOT_OFFICE_IPS'] = '192.168.1.'
      request = request_double(host: 'victory62.org', remote_ip: '192.168.1.77')
      expect(described_class.auto_test_request?(request)).to be(true)
    end

    it 'офисный пул: точный адрес и префикс подсети, чужие — нет' do
      old = ENV.fetch('SITE_CHATBOT_OFFICE_IPS', nil)
      ENV['SITE_CHATBOT_OFFICE_IPS'] = '192.168.1., 10.0.0.5'

      expect(described_class.office_ip?('192.168.1.77')).to be(true)
      expect(described_class.office_ip?('192.168.1.6')).to be(true)
      expect(described_class.office_ip?('10.0.0.5')).to be(true)
      expect(described_class.office_ip?('192.168.10.5')).to be(false)
      expect(described_class.office_ip?('203.0.113.10')).to be(false)
      expect(described_class.office_ip?(nil)).to be(false)
    ensure
      old.nil? ? ENV.delete('SITE_CHATBOT_OFFICE_IPS') : ENV['SITE_CHATBOT_OFFICE_IPS'] = old
    end
  end
end
