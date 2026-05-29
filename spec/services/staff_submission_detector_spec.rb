# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StaffSubmissionDetector do
  before do
    Rails.cache.clear # clear staff_firsts cache
    TelegramUser.create!(tg_user_id: 70_001, tg_username: 'irina', first_name: 'Ирина',
                         email: 'i.legaeva@yandex.ru', role: 'agent', status: 'active')
    TelegramUser.create!(tg_user_id: 70_002, first_name: 'Надежда', last_name: 'Синицина',
                         role: 'agent', status: 'active') # no tg_username — Iter 57 case
    User.create!(email: 'agent_x@victory62.org', password: SecureRandom.urlsafe_base64(20),
                 first_name: 'Sasha', last_name: 'Agent', role: :agent, active: true,
                 phone: '+79001234567')
  end

  describe '.detect' do
    context 'test_marker_email' do
      it 'распознаёт @test.example' do
        r = described_class.detect(email: 'phase2@test.example', name: 'X', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('test_marker_email')
      end

      it 'распознаёт example.com' do
        r = described_class.detect(email: 'foo@example.com', name: 'X', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('test_marker_email')
      end
    end

    context 'test_marker_name' do
      it 'распознаёт «Тест Клиент»' do
        r = described_class.detect(email: 'real@gmail.com', name: 'Тест Клиент', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('test_marker_name')
      end

      it 'распознаёт «Phase2 Test»' do
        r = described_class.detect(email: nil, name: 'Phase2 Test', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('test_marker_name')
      end
    end

    context 'email_staff_match' do
      it 'matches TelegramUser.email' do
        r = described_class.detect(email: 'i.legaeva@yandex.ru', name: 'Random', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('email_staff_match')
      end

      it 'matches User.role=agent' do
        r = described_class.detect(email: 'agent_x@victory62.org', name: 'Random', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('email_staff_match')
      end
    end

    context 'phone_staff_match' do
      it 'matches User phone last-10' do
        r = described_class.detect(email: nil, name: 'Random', phone: '8-900-123-4567')
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('phone_staff_match')
      end

      it 'не false-positive на short phone' do
        r = described_class.detect(email: nil, name: 'Random', phone: '12345')
        expect(r.staff_test).to be(false)
      end
    end

    context 'tg_staff_match' do
      it 'matches active TelegramUser tg_user_id' do
        r = described_class.detect(email: nil, name: 'X', phone: nil, tg_user_id: 70_001)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('tg_staff_match')
      end
    end

    context 'name_staff_first' do
      it 'matches «Надежда» (TelegramUser first_name)' do
        r = described_class.detect(email: nil, name: 'Надежда', phone: nil)
        expect(r.staff_test).to be(true)
        expect(r.matched_by).to eq('name_staff_first')
      end

      it 'не false-positive на «Ан» (< 3 chars)' do
        r = described_class.detect(email: nil, name: 'Ан', phone: nil)
        expect(r.staff_test).to be(false)
      end

      it 'не false-positive на «Анна» (имя клиента, не staff)' do
        r = described_class.detect(email: nil, name: 'Анна', phone: nil)
        expect(r.staff_test).to be(false)
      end
    end

    context 'no match — real client' do
      it 'возвращает staff_test=false' do
        r = described_class.detect(email: 'real.client@gmail.com', name: 'Иван Петров', phone: '+79991234567')
        expect(r.staff_test).to be(false)
        expect(r.matched_by).to be_nil
      end
    end

    context 'cascade priority' do
      it 'test_marker_email > all (если email phase-test, остальное игнорим)' do
        r = described_class.detect(email: 'phase2-test@test.example', name: 'Надежда', phone: nil)
        expect(r.matched_by).to eq('test_marker_email')
      end
    end
  end
end
