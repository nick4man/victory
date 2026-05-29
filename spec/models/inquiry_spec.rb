# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inquiry do
  def build_inquiry(attrs = {})
    described_class.new({
      inquiry_type: 'quick_inquiry',
      name: 'Тест Тестов',
      phone: '+79991234567',
      message: 'тестовое сообщение',
      source: 'site_form',
      status: 'new'
    }.merge(attrs))
  end

  describe 'enums' do
    it 'inquiry_type uses _prefix' do
      expect(build_inquiry(inquiry_type: 'mortgage')).to be_inquiry_type_mortgage
    end

    it 'status uses _prefix' do
      expect(build_inquiry(status: 'new')).to be_status_new
    end

    it 'priority uses _prefix' do
      expect(build_inquiry(priority: 'urgent')).to be_priority_urgent
    end
  end

  describe 'name validation' do
    it 'requires name' do
      i = build_inquiry(name: '')
      expect(i).not_to be_valid
      expect(i.errors[:name]).to be_present
    end

    it 'rejects name shorter than 2 chars' do
      expect(build_inquiry(name: 'X')).not_to be_valid
    end
  end

  describe 'phone validation' do
    context 'with default source=site_form' do
      it 'requires phone' do
        expect(build_inquiry(phone: nil)).not_to be_valid
      end

      it 'enforces 10-11 digit format' do
        i = build_inquiry(phone: '123')
        expect(i).not_to be_valid
        expect(i.errors[:phone]).to include(a_string_matching(/10-11/))
      end
    end

    context 'with source=tg_dm (Phase 4D)' do
      it 'allows blank phone' do
        i = build_inquiry(phone: nil, source: 'tg_dm')
        expect(i).to be_valid
      end

      it 'skips phone_format check (allows masked/short)' do
        i = build_inquiry(phone: '+7 999 ***-**-67', source: 'tg_dm')
        expect(i).to be_valid
      end
    end

    context 'with source=crm_webhook (Phase 4E)' do
      it 'allows blank phone' do
        expect(build_inquiry(phone: nil, source: 'crm_webhook')).to be_valid
      end

      it 'allows masked phone' do
        expect(build_inquiry(phone: '+7 999 ***-**-67', source: 'crm_webhook')).to be_valid
      end
    end

    it 'PHONE_OPTIONAL_SOURCES constant lists tg_dm + crm_webhook' do
      expect(described_class::PHONE_OPTIONAL_SOURCES).to contain_exactly('tg_dm', 'crm_webhook')
    end
  end

  describe 'email validation' do
    it 'allows blank email' do
      expect(build_inquiry(email: nil)).to be_valid
    end

    it 'rejects malformed email' do
      i = build_inquiry(email: 'not-an-email')
      expect(i).not_to be_valid
      expect(i.errors[:email]).to be_present
    end

    it 'accepts valid email' do
      expect(build_inquiry(email: 'user@example.com')).to be_valid
    end
  end

  describe 'attribution columns (Phase 4H)' do
    it 'persists client_tg_user_id' do
      i = build_inquiry(source: 'tg_dm', phone: nil, client_tg_user_id: 999_111)
      i.save!
      expect(i.reload.client_tg_user_id).to eq(999_111)
    end

    it 'persists client_phone_e164 + client_email_norm + attribution_source' do
      i = build_inquiry(
        client_phone_e164: '79991234567',
        client_email_norm: 'a@b.com',
        attribution_source: 'site_form'
      )
      i.save!
      i.reload
      expect(i.client_phone_e164).to eq('79991234567')
      expect(i.client_email_norm).to eq('a@b.com')
      expect(i.attribution_source).to eq('site_form')
    end
  end

  describe 'scopes' do
    let!(:new_inq)       { build_inquiry(status: 'new').tap(&:save!) }
    let!(:contacted)     { build_inquiry(status: 'contacted').tap(&:save!) }
    let!(:cancelled_inq) { build_inquiry(status: 'cancelled').tap(&:save!) }

    it 'active includes new/contacted/in_progress/scheduled' do
      expect(described_class.active).to include(new_inq, contacted)
      expect(described_class.active).not_to include(cancelled_inq)
    end

    it 'pending = new only' do
      expect(described_class.pending).to contain_exactly(new_inq)
    end

    it 'archived = completed + cancelled' do
      expect(described_class.archived).to include(cancelled_inq)
      expect(described_class.archived).not_to include(new_inq)
    end
  end

  describe 'AASM transitions' do
    let(:inquiry) { build_inquiry.tap(&:save!) }

    it 'starts in :new state' do
      expect(inquiry).to be_status_new
    end

    it 'can contact from new' do
      inquiry.contact!
      expect(inquiry).to be_status_contacted
      expect(inquiry.processed_at).to be_present
    end

    it 'mark_as_spam transitions new → spam' do
      inquiry.mark_as_spam!
      expect(inquiry).to be_status_spam
    end

    it 'completion transition sets completed_at' do
      inquiry.contact!
      inquiry.complete!
      expect(inquiry.completed_at).to be_within(2.seconds).of(Time.current)
    end
  end
end
