# frozen_string_literal: true

require 'rails_helper'

# Issue #277 — карточка лида дашборда: рендер полей, клавиатура действий через
# существующие callback-механики, confirm + soft-delete, back на страницу списка.
RSpec.describe Telegram::WorkBot::DashboardLeadCard do
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 120_101, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 120_101)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 120_102, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end

  let(:metadata) do
    {
      'name' => 'Анна Смирнова', 'phone' => '+79001234567', 'email' => 'anna@example.com',
      'summary' => 'Есенина 29, 2-комн', 'budget' => 'до 6 млн', 'comment' => 'перезвонить вечером',
      'priority' => 'urgent', 'service_type' => 'express', 'returning_client' => true,
      'ip' => '85.140.12.34', 'user_agent' => 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)',
      'stage_history' => [
        { 'at' => 3.hours.ago.iso8601, 'from' => 'new', 'to' => 'first_contact', 'by' => '@oks' },
        { 'at' => 1.hour.ago.iso8601, 'from' => 'first_contact', 'to' => 'show', 'by' => '@irina' }
      ],
      'assign_history' => [
        { 'at' => 2.hours.ago.iso8601, 'by_mention' => '@oks', 'to_mention' => '@irina' }
      ],
      'notes' => [
        { 'at' => 30.minutes.ago.iso8601, 'by' => 'irina', 'text' => 'просит перезвонить после 18:00' }
      ]
    }
  end

  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'show',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 555,
                      assigned_to: agent, segment: 'mortgage_approved', metadata: metadata)
  end

  def card(lead_record = lead)
    described_class.new(lead: lead_record)
  end

  def keyboard_callbacks(result)
    result.keyboard[:inline_keyboard].flatten.map { |b| b[:callback_data] }
  end

  describe 'рендер полей' do
    it 'показывает контакт, стадию, ответственного, метки, ip-контекст и бюджет' do
      text = card.call.text

      expect(text).to include("Лид ##{lead.id}")
      expect(text).to include('🏠 показ')
      expect(text).to include('Анна Смирнова', '+79001234567', 'anna@example.com')
      expect(text).to include('Назначен: Ирина')
      expect(text).to include('🏦 Ипотека одобрена', '🔥 URGENT', '🔵 EXPRESS', '🔄 возвратный')
      expect(text).to include('🌐 IP: 85.140.12.34', 'Mozilla/5.0 (iPhone')
      expect(text).to include('перезвонить вечером', 'Есенина 29', 'до 6 млн')
      expect(text).to include(Formatters::DateFormat.fmt_dt(lead.created_at))
    end

    it 'рисует компактный таймлайн последних событий (новые сверху)' do
      text = card.call.text

      expect(text).to include('<b>История:</b>')
      expect(text).to include('стадия: first_contact → show (@irina)')
      expect(text).to include('назначен: @irina (@oks)')
      expect(text).to include('заметка: просит перезвонить после 18:00 (irina)')
      expect(text.index('заметка:')).to be < text.index('стадия: first_contact → show')
      expect(text.index('стадия: first_contact → show')).to be < text.index('стадия: new → first_contact')
    end

    it 'таймлайн ограничен пятью последними событиями' do
      lead.update!(metadata: metadata.merge(
        'notes' => Array.new(8) { |i| { 'at' => (i + 1).minutes.ago.iso8601, 'by' => 'irina', 'text' => "нота #{i}" } }
      ))

      history_lines = card.call.text.lines.grep(/^  · /)
      expect(history_lines.size).to eq(5)
      expect(history_lines.first).to include('нота 0')
    end

    it 'без ip в metadata строки 🌐 нет' do
      lead.update!(metadata: metadata.except('ip', 'user_agent'))

      expect(card.call.text).not_to include('🌐')
    end

    it 'экранирует HTML в пользовательских данных' do
      lead.update!(metadata: metadata.merge('name' => '<b>Анна</b>'))

      expect(card.call.text).to include('&lt;b&gt;Анна&lt;/b&gt;')
    end

    it 'неназначенный лид — «Не назначен»' do
      lead.update!(assigned_to: nil)

      expect(card.call.text).to include('👤 Не назначен')
    end
  end

  describe 'клавиатура действий' do
    it 'стадия/назначение/спам — существующие callback_data якорной карточки' do
      callbacks = keyboard_callbacks(card.call)

      expect(callbacks).to include("stage:#{lead.id}:show", "stage:#{lead.id}:contract",
                                   "assign:#{lead.id}", "spam:#{lead.id}",
                                   "wiz:s:lead_edit:#{lead.id}:p1", "dashboard:lead:#{lead.id}:del",
                                   "dashboard:lead:#{lead.id}")
    end

    # Ревью #280 (раунд 2): кнопка редактирования несёт контекст возврата —
    # страницу списка на момент открытия карточки; wizard перерисует карточку
    # с ним, и «Назад» после сохранения не уедет на пересчитанную страницу.
    it 'кнопка редактирования несёт страницу списка, где лид лежит сейчас' do
      leads = Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" }).tap do |le|
          le.update_column(:updated_at, (12 - i).minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      expect(keyboard_callbacks(card(leads.first).call)).to include("wiz:s:lead_edit:#{leads.first.id}:p2")
      expect(keyboard_callbacks(card(leads.last).call)).to include("wiz:s:lead_edit:#{leads.last.id}:p1")
    end

    it 'у закрытого лида нет ряда стадий' do
      lead.update!(current_stage: 'closed_won')

      callbacks = keyboard_callbacks(card.call)
      expect(callbacks.grep(/\Astage:/)).to be_empty
      expect(callbacks).to include("assign:#{lead.id}", "dashboard:lead:#{lead.id}:del")
    end

    it 'back ведёт на страницу списка, где лид лежит' do
      # 12 открытых лидов с детерминированным updated_at: самый старый — на 2-й
      # странице (PAGE_SIZE = 8). Список сортирует updated_at desc, id desc.
      leads = Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" }).tap do |le|
          le.update_column(:updated_at, (12 - i).minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      oldest = leads.first

      expect(keyboard_callbacks(card(oldest).call)).to include('dashboard:leads:p:2')
      expect(keyboard_callbacks(card(leads.last).call)).to include('dashboard:leads:p:1')
    end
  end

  describe 'удаление' do
    it 'confirm_delete просит подтверждение и ничего не меняет' do
      result = card.confirm_delete

      expect(result.text).to include("Удалить лид ##{lead.id}?", 'Анна Смирнова')
      expect(keyboard_callbacks(result)).to eq(["dashboard:lead:#{lead.id}:del:yes", "dashboard:lead:#{lead.id}"])
      expect(lead.reload.deleted_at).to be_nil
    end

    it 'perform_delete — soft-delete: deleted_at, не destroy; лид исчезает из .real' do
      lead # форсируем создание до замера count
      expect { card.perform_delete(actor: manager) }.not_to(change { LeadEvent.unscoped.count })

      lead.reload
      expect(lead.deleted_at).to be_present
      expect(lead.current_stage).to eq('show')
      expect(lead.metadata['deleted_by']).to eq('@oks')
      expect(LeadEvent.real.where(id: lead.id)).to be_empty
      expect(LeadEvent.open.real.where(id: lead.id)).to be_empty
      expect(LeadEvent.unscoped.where(id: lead.id)).to exist
    end

    it 'perform_delete возвращает кнопку назад на исходную страницу списка' do
      leads = Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" }).tap do |le|
          le.update_column(:updated_at, (12 - i).minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      result = card(leads.first).perform_delete(actor: manager)
      expect(keyboard_callbacks(result)).to eq(['dashboard:leads:p:2'])
    end

    # Ревью #280: soft-delete сериализован с выгрузкой в CRM — perform_delete
    # берёт ту же блокировку строки, что CrmCards::Workflow#export_with_lock.
    it 'perform_delete обновляет лид под with_lock' do
      allow(lead).to receive(:with_lock).and_call_original

      card.perform_delete(actor: manager)

      expect(lead).to have_received(:with_lock)
      expect(lead.reload.deleted_at).to be_present
    end
  end

  # Ревью #280 — карточка, открытая из карточки сотрудника (origin
  # s<staff_id>:<page>): «Назад»/«Отмена»/после удаления ведут обратно в
  # карточку сотрудника на ту же страницу, а не в общий список лидов.
  describe 'origin из карточки сотрудника' do
    let(:origin) { { staff_id: agent.id, staff_page: 2 } }

    def origin_card(lead_record = lead)
      described_class.new(lead: lead_record, origin: origin)
    end

    it '«Назад» и «Обновить» ссылаются на карточку сотрудника / карточку с origin' do
      callbacks = keyboard_callbacks(origin_card.call)

      expect(callbacks).to include("dashboard:staff:#{agent.id}:2")
      expect(callbacks).to include("dashboard:lead:#{lead.id}:s#{agent.id}:2")
      expect(callbacks).not_to include('dashboard:leads:p:1')
    end

    # Ревью #280 (раунд 2): wizard редактирования получает origin и после
    # сохранения перерисовывает карточку с ним.
    it 'кнопка редактирования несёт origin' do
      expect(keyboard_callbacks(origin_card.call)).to include("wiz:s:lead_edit:#{lead.id}:s#{agent.id}:2")
    end

    it 'origin из списка лидов (list_page) — назад на зафиксированную страницу' do
      list_card = described_class.new(lead: lead, origin: { list_page: 2 })
      callbacks = keyboard_callbacks(list_card.call)

      expect(callbacks).to include('dashboard:leads:p:2')
      expect(callbacks).to include("wiz:s:lead_edit:#{lead.id}:p2")
      expect(callbacks).to include("dashboard:lead:#{lead.id}:p2:del")
    end

    it 'кнопки удаления несут origin: confirm, del:yes и отмена' do
      expect(keyboard_callbacks(origin_card.call)).to include("dashboard:lead:#{lead.id}:s#{agent.id}:2:del")

      confirm = origin_card.confirm_delete
      expect(keyboard_callbacks(confirm)).to eq(["dashboard:lead:#{lead.id}:s#{agent.id}:2:del:yes",
                                                 "dashboard:lead:#{lead.id}:s#{agent.id}:2"])
    end

    it 'после удаления — кнопка назад в карточку сотрудника' do
      result = origin_card.perform_delete(actor: manager)

      expect(keyboard_callbacks(result)).to eq(["dashboard:staff:#{agent.id}:2"])
      expect(result.keyboard[:inline_keyboard].flatten.first[:text]).to include('сотрудника')
      expect(lead.reload.deleted_at).to be_present
    end
  end
end
