# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Sla::WatchdogJob do
  let(:agent) do
    TelegramUser.create!(tg_user_id: 7001, tg_username: 'agent', first_name: 'Агент',
                         role: 'agent', status: 'active', dm_chat_id: 555)
  end

  def lead(assigned_at:, **overrides)
    LeadEvent.create!({
      lead_ref: create(:inquiry),
      source: 'site_form',
      current_stage: 'new',
      anchor_topic_key: 'dispatcher',
      tg_chat_id: -100_123,
      assigned_to: agent,
      assigned_at: assigned_at,
      first_contact_at: nil,
      closed_at: nil
    }.merge(overrides))
  end

  it 'ставит пинг по лиду, просрочившему SLA' do
    overdue = lead(assigned_at: 45.minutes.ago)

    expect { described_class.perform_now }
      .to have_enqueued_job(Telegram::WorkBot::Sla::PingJob)
      .with(overdue.id, :first_contact_overdue)
  end

  it 'не трогает лид, у которого SLA ещё не вышел' do
    lead(assigned_at: 10.minutes.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(Telegram::WorkBot::Sla::PingJob)
  end

  # Регрессия: без верхней границы сторож мьютит бота. `PingService` дедуплицирует
  # не чаще раза в 30 мин, но общего числа повторов не ограничивает — брошенный
  # лид пинговался бы вечно, ~28 раз в сутки, пока кто-то не закроет его руками.
  it 'не пингует брошенный лид старше BACKLOG_HORIZON' do
    lead(assigned_at: (described_class::BACKLOG_HORIZON + 1.hour).ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(Telegram::WorkBot::Sla::PingJob)
  end

  it 'считает брошенные лиды отдельно, а не прячет их' do
    lead(assigned_at: (described_class::BACKLOG_HORIZON + 1.hour).ago)
    lead(assigned_at: 45.minutes.ago)

    expect(described_class.perform_now).to include(enqueued: 1, abandoned: 1)
  end

  it 'пропускает лид с проставленным first_contact_at' do
    lead(assigned_at: 45.minutes.ago, first_contact_at: 40.minutes.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(Telegram::WorkBot::Sla::PingJob)
  end
end
