# frozen_string_literal: true

require 'rails_helper'

# Антиспам-гейт POST /properties/:id/report (issue #262, часть 2): произвольный
# текст уходит админам письмом без всякого лимита. Теперь IP-гейт + rate limit
# до AdminMailer. Дроп молчаливый — redirect с success-нотисом (образец #255).
RSpec.describe 'Антиспам-гейт /properties/:id/report', type: :request do
  around do |example|
    old = ENV.fetch('TG_WORK_BOT_DISABLED', nil)
    ENV['TG_WORK_BOT_DISABLED'] = 'true'
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
    Rails.cache = original_cache
    old.nil? ? ENV.delete('TG_WORK_BOT_DISABLED') : ENV['TG_WORK_BOT_DISABLED'] = old
    travel_back
  end

  let(:property) { create(:property) }
  let(:report_params) { { reason: 'fraud', description: 'Подозрительное объявление, проверьте документы' } }

  def submit_report(headers: {})
    post report_property_path(property), params: report_params, headers: headers
  end

  it 'принимает жалобу с чистого IP: письмо админам уходит' do
    expect { submit_report }
      .to have_enqueued_job(ActionMailer::MailDeliveryJob).at_least(:once)

    expect(response).to redirect_to(property_path(property))
    expect(flash[:notice]).to eq('Жалоба отправлена. Спасибо за информацию!')
  end

  it 'дропает submit с IP из блэклиста до AdminMailer: success-redirect, без письма' do
    SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
    allow(Rails.logger).to receive(:info)

    expect { submit_report(headers: { 'REMOTE_ADDR' => '80.94.95.173' }) }
      .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

    expect(response).to redirect_to(property_path(property))
    expect(flash[:notice]).to eq('Жалоба отправлена. Спасибо за информацию!')
    expect(Rails.logger).to have_received(:info).with(/reason=spam_ip/)
  end

  it 'дропает submit из CIDR-подсети блэклиста' do
    SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '45.128.232.0/24', source: 'firehol')

    expect { submit_report(headers: { 'REMOTE_ADDR' => '45.128.232.202' }) }
      .not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

    expect(response).to redirect_to(property_path(property))
  end

  it 'дропает заполненный honeypot до AdminMailer' do
    expect do
      post report_property_path(property),
           params: report_params.merge(PublicFormSpamGate::HONEYPOT_PARAM => 'http://spam.example')
    end.not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

    expect(response).to redirect_to(property_path(property))
    expect(flash[:notice]).to eq('Жалоба отправлена. Спасибо за информацию!')
  end

  it 'режет флуд: четвёртая жалоба за час с одного IP не уходит админам' do
    3.times { submit_report }

    expect { submit_report }.not_to have_enqueued_job(ActionMailer::MailDeliveryJob)

    # Молчаливый дроп: ответ неотличим от принятой жалобы.
    expect(response).to redirect_to(property_path(property))
    expect(flash[:notice]).to eq('Жалоба отправлена. Спасибо за информацию!')
    expect(Rails.cache.read(PublicFormSpamGate.counter_key('property_report', 'rate_limit')).to_i).to eq 1
  end

  it 'не расходует лимит на дропы: жалобы с чистого IP проходят после флуда с заблокированного' do
    SpamBlockedEntry.create!(entry_type: :ip, status: :blocked, value: '80.94.95.173', source: 'firehol')
    3.times { submit_report(headers: { 'REMOTE_ADDR' => '80.94.95.173' }) }

    expect { submit_report(headers: { 'REMOTE_ADDR' => '203.0.113.10' }) }
      .to have_enqueued_job(ActionMailer::MailDeliveryJob).at_least(:once)
  end
end
