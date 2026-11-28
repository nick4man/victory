# frozen_string_literal: true

require 'rails_helper'

# Карантин первого контакта (issue #286): IP без истории заявок + негативная
# классификация текста → Inquiry создаётся с меткой quarantine, но карточка
# в ДИСПЕТЧЕРСКУЮ не публикуется (Inquiry#push_to_work_bot — no-op).
RSpec.describe Lead::FirstContactQuarantine do
  let(:new_ip) { '203.0.113.200' }
  let(:base_attrs) do
    {
      inquiry_type: 'contact_agent',
      name: 'Пётр Тестовый',
      phone: '79000000000',
      message: 'текст заявки',
      source: 'contact_form',
      ip_address: new_ip
    }
  end

  describe '#call' do
    it 'первый контакт + негативная классификация → карантин' do
      expect(described_class.new(ip: new_ip, classification: true).call).to be(true)
    end

    it 'вердикт-объект с #negative? поддерживается (интерфейс LLM-фильтра форм)' do
      verdict = Struct.new(:negative?).new(true)
      expect(described_class.new(ip: new_ip, classification: verdict).call).to be(true)

      passed = Struct.new(:negative?).new(false)
      expect(described_class.new(ip: new_ip, classification: passed).call).to be(false)
    end

    it 'позитивная классификация → не карантин, даже с нового IP' do
      expect(described_class.new(ip: new_ip, classification: false).call).to be(false)
      expect(described_class.new(ip: new_ip, classification: nil).call).to be(false)
    end

    it 'IP с историей заявок → не карантин, даже с негативной классификацией' do
      create(:inquiry, ip_address: new_ip)

      expect(described_class.new(ip: new_ip, classification: true).call).to be(false)
    end

    it 'пустой IP → не карантин (без идентификатора публикацию не подавляем)' do
      expect(described_class.new(ip: '', classification: true).call).to be(false)
      expect(described_class.new(ip: nil, classification: true).call).to be(false)
    end
  end

  describe '#apply' do
    it 'дописывает метку quarantine в attrs, не затирая существующую metadata' do
      attrs = base_attrs.merge(metadata: { 'suspicious' => true, 'contact_form_spam_reason' => 'too_fast' })

      result = described_class.new(ip: new_ip, classification: true).apply(attrs)

      expect(result[:metadata]['quarantine']).to be(true)
      expect(result[:metadata]['quarantine_reason']).to eq(described_class::REASON)
      expect(result[:metadata]['quarantined_at']).to be_present
      expect(result[:metadata]['suspicious']).to be(true)
    end

    it 'без условий карантина возвращает attrs без изменений' do
      attrs = base_attrs.dup

      expect(described_class.new(ip: new_ip, classification: false).apply(attrs)).to eq(attrs)
    end
  end

  describe 'карантинный лид end-to-end (критерий приёмки issue #286)' do
    it 'Inquiry создана с меткой, карточка в ДИСПЕТЧЕРСКУЮ не опубликована' do
      # and_call_original: если подавление сломано, реальный Intake создаст
      # LeadEvent — спек это поймает. TG-вызовы анонсера закрыты глобальным
      # стабом external_services (#227: боевые чаты чисты).
      allow(Lead::Intake).to receive(:call).and_call_original
      attrs = described_class.new(ip: new_ip, classification: true).apply(base_attrs)

      inquiry = Inquiry.create!(attrs)
      # after_create_commit в спеке может не сработать — вызываем пуш явно;
      # для карантинного лида оба пути обязаны быть no-op.
      inquiry.send(:push_to_work_bot)

      expect(inquiry).to be_persisted
      expect(inquiry).to be_quarantined
      expect(inquiry.metadata['quarantine']).to be(true)
      expect(inquiry.metadata['quarantine_reason']).to eq(described_class::REASON)
      expect(Lead::Intake).not_to have_received(:call)
      expect(LeadEvent.where(lead_ref: inquiry)).to be_empty
    end

    it 'лид с известного IP публикуется как обычно (регрессия)' do
      create(:inquiry, ip_address: new_ip)
      allow(Lead::Intake).to receive(:call)

      attrs = described_class.new(ip: new_ip, classification: true).apply(base_attrs)
      inquiry = Inquiry.create!(attrs)
      inquiry.send(:push_to_work_bot)

      expect(inquiry).not_to be_quarantined
      # after_create_commit в Rails 8 срабатывает и в транзакционной спеке,
      # поэтому вызовов может быть два (create + явный) — важен сам факт пуша.
      expect(Lead::Intake).to have_received(:call).at_least(:once)
    end
  end
end
