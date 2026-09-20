# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCard do
  let(:author) { TelegramUser.create!(tg_user_id: 98_001, tg_username: 'irina', role: 'agent', status: 'active') }

  def lead_event
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: -100_1)
  end

  it 'по умолчанию — черновик с пустыми данными и без замечаний' do
    card = described_class.create!(kind: 'lead', author: author)

    expect(card).to be_status_draft
    expect(card).to be_kind_lead
    expect(card.payload).to eq({})
    expect(card.check_errors).to eq([])
  end

  it 'мягкое удаление прячет карточку из default scope' do
    card = described_class.create!(kind: 'object', author: author)
    card.update!(deleted_at: Time.current)

    expect(described_class.find_by(id: card.id)).to be_nil
    expect(described_class.unscoped.find_by(id: card.id)).to be_present
  end

  it 'одна карточка заявки на лид' do
    lead = lead_event
    described_class.create!(kind: 'lead', author: author, lead_event: lead)

    expect { described_class.create!(kind: 'lead', author: author, lead_event: lead) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'карточек объектов без лида может быть сколько угодно' do
    2.times { described_class.create!(kind: 'object', author: author) }

    expect(described_class.kind_object.count).to eq(2)
  end

  it 'check_passed? — только после проверки и без замечаний' do
    card = described_class.new(kind: 'lead', author: author)
    expect(card.check_passed?).to be(false)

    card.checked_at = Time.current
    expect(card.check_passed?).to be(true)

    card.check_errors = [{ 'field' => 'phone', 'message' => 'не заполнено' }]
    expect(card.check_passed?).to be(false)
  end

  it 'export_stale? — заявка застряла в выгрузке или в одобрении дольше 15 минут' do
    card = described_class.create!(kind: 'lead', author: author, status: 'exporting')
    expect(card.export_stale?).to be(false)

    card.update_columns(updated_at: 16.minutes.ago)
    expect(card.export_stale?).to be(true)

    # Одобренная, но не разрешённая карточка ждёт человека, а не джоба.
    card.update_columns(status: 'approved')
    expect(card.reload.export_stale?).to be(false)

    card.update_columns(released_at: 16.minutes.ago, updated_at: 16.minutes.ago)
    expect(card.reload.export_stale?).to be(true)

    object = described_class.create!(kind: 'object', author: author, status: 'approved')
    object.update_columns(updated_at: 1.day.ago)
    expect(object.export_stale?).to be(false) # объект вносят вручную — «застрять» ему негде
  end

  it 'responsible — у заявки текущий ответственный по лиду, у объекта — автор' do
    petr = TelegramUser.create!(tg_user_id: 98_002, tg_username: 'petr', status: 'active')
    lead = lead_event
    card = described_class.create!(kind: 'lead', author: author, lead_event: lead)
    expect(card.responsible).to eq(author)

    lead.update!(assigned_to: petr)
    expect(card.reload.responsible).to eq(petr)

    expect(described_class.create!(kind: 'object', author: author).responsible).to eq(author)
  end

  it 'журнал упорядочен по времени, последний комментарий возврата доступен' do
    card = described_class.create!(kind: 'lead', author: author)
    card.transitions.create!(from_status: 'draft', to_status: 'pending_review', actor: author)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: author,
                             comment: 'Уточни бюджет')

    expect(card.reload.transitions.map(&:to_status)).to eq(%w[pending_review needs_rework])
    expect(card.last_rework_comment).to eq('Уточни бюджет')
  end

  it 'у каждого статуса есть подпись' do
    expect(described_class::STATUS_LABELS.keys).to match_array(described_class.statuses.keys)
  end
end
