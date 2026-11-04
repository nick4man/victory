# frozen_string_literal: true

require 'rails_helper'

# Путь карточки заявки глазами людей: автор → модератор → автор → модератор.
# Все нажатия — настоящими callback_data из присланных сообщений.
RSpec.describe 'модерация карточки CRM в Telegram' do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent)    { crm_staff(tg_user_id: 98_941, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_942, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 555,
                      assigned_to: agent, first_contact_at: 1.hour.ago)
  end
  let!(:card) do
    CrmCards::Workflow.new(notifier: instance_double(CrmCards::Notifier)).upsert_lead_card!(
      lead: lead, actor: agent,
      values: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
                'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' }
    ).card
  end

  def last_dm_to(user)
    dms.reverse.find { |m| m[:chat_id] == user.dm_chat_id }
  end

  it 'на модерацию → возврат с комментарием → повторная отправка → одобрение → выгрузка в очереди' do
    tap_callback("crm_card:#{card.id}:submit", user: agent)
    expect(card.reload).to be_status_pending_review
    expect(acks.last.first).to include('Отправлено на модерацию')
    expect(last_dm_to(director)[:text]).to include('На модерацию', '@irina')

    press('На доработку', user: director, message: last_dm_to(director))
    expect(last_text).to include("Что доработать в карточке ##{card.id}?")
    say('Уточни бюджет и срок покупки', user: director)
    # Подтверждение называет карточку и автора — промах по кнопке виден заранее.
    expect(last_text).to include("Вернуть карточку ##{card.id} автору @irina")
    press('Вернуть', user: director)
    expect(card.reload).to be_status_needs_rework
    expect(last_dm_to(agent)[:text]).to include('вернулась на доработку', 'Уточни бюджет и срок покупки')

    tap_callback("crm_card:#{card.id}:submit", user: agent)
    expect(card.reload).to be_status_pending_review

    tap_callback("wiz:s:crm_approve:#{card.id}", user: director)
    expect(last_text).to include("карточке ##{card.id}", '@irina')
    # Одобрение само в CRM не отправляет — это отдельное решение руководителя.
    expect { press('Одобрить', user: director) }.not_to have_enqueued_job(CrmCards::ExportJob)
    expect(card.reload).to be_status_approved
    expect(card.released_at).to be_nil

    tap_callback("wiz:s:crm_release:#{card.id}", user: director)
    expect(last_text).to include("карточке ##{card.id}", '@irina', 'Отменить запись в CRM нельзя')
    expect { press('Выгрузить', user: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    expect(card.reload.released_by_id).to eq(director.id)
  end

  it 'повторное нажатие «На модерацию» не создаёт второго перехода' do
    tap_callback("crm_card:#{card.id}:submit", user: agent)
    tap_callback("crm_card:#{card.id}:submit", user: agent)

    expect(acks.last.first).to include('на модерации')
    expect(acks.last.last).to be(true)
    expect(card.transitions.count).to eq(1)
  end

  it 'агент не может запустить одобрение даже прямым callback_data' do
    card.update!(status: 'pending_review')

    tap_callback("wiz:s:crm_approve:#{card.id}", user: agent)

    expect(last_text).to include('принимает модератор')
    expect(card.reload).to be_status_pending_review
  end

  it 'кнопка статуса под лидом: карточку — в личку; посторонним — отказ' do
    tap_callback("crm_card:#{card.id}:view", user: agent, chat_type: 'supergroup')
    expect(dms.last[:chat_id]).to eq(agent.dm_chat_id)
    expect(acks.last.first).to include('личке')

    petr = crm_staff(tg_user_id: 98_943, username: 'petr')
    tap_callback("crm_card:#{card.id}:view", user: petr, chat_type: 'supergroup')
    expect(acks.last).to eq(['🚫 Карточку видят автор, ответственный по лиду и модераторы.', true])
  end

  it 'повтор выгрузки — кнопкой модератора' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    expect { tap_callback("crm_card:#{card.id}:retry", user: director) }
      .to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    expect(card.reload).to be_status_approved
  end
end
