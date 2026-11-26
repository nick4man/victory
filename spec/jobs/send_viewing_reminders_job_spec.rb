# frozen_string_literal: true

require 'rails_helper'

# Запрос джобы приведён к реальным колонкам viewing_schedules (PR #272):
# confirmed + scheduled_at завтра + reminder_sent: false. Сама джоба в
# расписание не добавлена — спек фиксирует отбор перед будущим включением.
RSpec.describe SendViewingRemindersJob, type: :job do
  let(:property) { create(:property) }

  def create_viewing(scheduled_at:, status: 'confirmed', reminder_sent: false)
    ViewingSchedule.new(
      property: property, name: 'Иван Петров', phone: '+7 (900) 123-45-67',
      status: status, scheduled_at: scheduled_at, ends_at: scheduled_at + 60.minutes,
      reminder_sent: reminder_sent
    ).tap { |v| v.save!(validate: false) }
  end

  let!(:tomorrow_confirmed) { create_viewing(scheduled_at: Date.tomorrow.in_time_zone + 10.hours) }
  let!(:tomorrow_confirmed_later) { create_viewing(scheduled_at: Date.tomorrow.in_time_zone + 15.hours) }
  let!(:today_confirmed) { create_viewing(scheduled_at: Date.current.in_time_zone + 10.hours) }
  let!(:tomorrow_pending) { create_viewing(scheduled_at: Date.tomorrow.in_time_zone + 12.hours, status: 'pending') }
  let!(:tomorrow_reminded) do
    create_viewing(scheduled_at: Date.tomorrow.in_time_zone + 16.hours, reminder_sent: true)
  end

  it 'ставит ViewingNotificationJob только завтрашним confirmed без reminder_sent' do
    expect { described_class.perform_now }
      .to have_enqueued_job(ViewingNotificationJob).with(tomorrow_confirmed.id, 'reminder')
      .and have_enqueued_job(ViewingNotificationJob).with(tomorrow_confirmed_later.id, 'reminder')
      .and have_enqueued_job(ViewingNotificationJob).exactly(2).times
  end

  it 'не трогает сегодняшние, неподтверждённые и уже напомненные показы' do
    described_class.perform_now

    expect(ViewingNotificationJob).not_to have_been_enqueued.with(today_confirmed.id, 'reminder')
    expect(ViewingNotificationJob).not_to have_been_enqueued.with(tomorrow_pending.id, 'reminder')
    expect(ViewingNotificationJob).not_to have_been_enqueued.with(tomorrow_reminded.id, 'reminder')
  end
end
