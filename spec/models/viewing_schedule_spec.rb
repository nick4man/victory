# frozen_string_literal: true

require 'rails_helper'

# Модель приведена к схеме viewing_schedules (t_6bbf76ae): preferred_date /
# preferred_time — виртуальные поля формы, собираемые в scheduled_at/ends_at;
# валидации и scope'ы работают на реальных колонках.
RSpec.describe ViewingSchedule, type: :model do
  let(:property) { create(:property) }

  def build_viewing(attrs = {})
    described_class.new({
      property: property, name: 'Иван Петров', phone: '+7 (900) 123-45-67',
      preferred_date: Date.tomorrow, preferred_time: '10:00', status: 'pending'
    }.merge(attrs))
  end

  describe 'сборка scheduled_at/ends_at из виртуальных полей формы' do
    it 'собирает scheduled_at и ends_at (duration по умолчанию 60)' do
      viewing = build_viewing

      expect(viewing).to be_valid
      expect(viewing.scheduled_at).to eq(Date.tomorrow.in_time_zone + 10.hours)
      expect(viewing.ends_at).to eq(viewing.scheduled_at + 60.minutes)
      expect(viewing.duration_minutes).to eq(60)
    end

    it 'сохранённая запись деривирует preferred_date/preferred_time из scheduled_at' do
      viewing = build_viewing
      viewing.save!

      reloaded = described_class.find(viewing.id)
      expect(reloaded.preferred_date).to eq(Date.tomorrow)
      expect(reloaded.preferred_time).to eq('10:00')
      expect(reloaded.datetime).to eq(viewing.scheduled_at)
    end

    it 'не затирает ends_at, выставленный вручную' do
      viewing = build_viewing(ends_at: Date.tomorrow.in_time_zone + 12.hours)

      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 12.hours)
    end

    it 'отклоняет некорректное время' do
      viewing = build_viewing(preferred_time: '25:99')

      expect(viewing).not_to be_valid
      expect(viewing.errors[:preferred_time]).to be_present
    end
  end

  describe 'валидации' do
    it 'не пускает дату в прошлом' do
      viewing = build_viewing(preferred_date: Date.yesterday)

      expect(viewing).not_to be_valid
      expect(viewing.errors[:preferred_date]).to include('не может быть в прошлом')
    end

    it 'не пускает на занятый слот того же объекта (пересечение диапазонов)' do
      build_viewing.save!

      conflict = build_viewing
      expect(conflict).not_to be_valid
      expect(conflict.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
    end

    it 'пропускает смежный слот без пересечения' do
      build_viewing.save!

      adjacent = build_viewing(preferred_time: '11:00')
      expect(adjacent).to be_valid
    end

    it 'игнорирует отменённые показы при проверке слота' do
      build_viewing(status: 'cancelled').save!

      expect(build_viewing).to be_valid
    end

    it 'пропускает тот же слот на другом объекте' do
      build_viewing.save!

      expect(build_viewing(property: create(:property))).to be_valid
    end
  end

  describe 'scope\'ы на scheduled_at' do
    let!(:past_viewing) do
      # Вчерашний показ: date_not_in_past на создании не пройти, а
      # save(validate: false) пропускает и before_validation-сборку
      # scheduled_at — поэтому колонки выставляем напрямую.
      build_viewing.tap do |v|
        v.scheduled_at = Date.yesterday.in_time_zone + 8.hours
        v.ends_at = v.scheduled_at + 60.minutes
        v.save!(validate: false)
      end
    end
    let!(:today_viewing) { build_viewing(preferred_time: '10:00').tap(&:save!) }
    let!(:done_viewing) do
      build_viewing(preferred_time: '12:00', status: 'completed').tap(&:save!)
    end

    it 'upcoming — сегодня и позже, только pending/confirmed' do
      expect(described_class.upcoming).to include(today_viewing)
      expect(described_class.upcoming).not_to include(past_viewing, done_viewing)
    end

    it 'past — строго раньше сегодняшнего дня' do
      expect(described_class.past).to include(past_viewing)
      expect(described_class.past).not_to include(today_viewing)
    end

    it 'today — календарный день по scheduled_at' do
      travel_to Date.tomorrow.in_time_zone + 9.hours do
        expect(described_class.today).to include(today_viewing)
        expect(described_class.today).not_to include(past_viewing)
      end
    end
  end
end
