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

  describe 'жизненный цикл прошедших показов (блокер 1 ревью #272)' do
    let(:past_viewing) do
      described_class.new(
        property: property, name: 'Иван Петров', phone: '+7 (900) 123-45-67',
        status: 'pending',
        scheduled_at: Date.yesterday.in_time_zone + 10.hours,
        ends_at: Date.yesterday.in_time_zone + 11.hours
      ).tap { |v| v.save!(validate: false) }
    end

    it 'complete! на вчерашнем показе проходит (date_not_in_past — только для слота)' do
      expect(past_viewing.complete!).to be(true)
      expect(past_viewing.reload.status).to eq('completed')
    end

    it 'mark_no_show! и cancel! на вчерашнем показе проходят' do
      expect(past_viewing.mark_no_show!).to be(true)
      expect(past_viewing.reload.status).to eq('no_show')

      other = described_class.new(
        property: property, name: 'Иван Петров', phone: '+7 (900) 123-45-67',
        status: 'confirmed',
        scheduled_at: Date.yesterday.in_time_zone + 12.hours,
        ends_at: Date.yesterday.in_time_zone + 13.hours
      ).tap { |v| v.save!(validate: false) }
      expect(other.cancel!('клиент не пришёл')).to be(true)
    end

    it 'перенос показа в прошлое по-прежнему запрещён' do
      viewing = build_viewing.tap(&:save!)
      viewing.preferred_date = Date.yesterday

      expect(viewing).not_to be_valid
      expect(viewing.errors[:preferred_date]).to include('не может быть в прошлом')
    end

    it 'confirm! вчерашнего pending отклоняется (активация прошедшего — блокер 1 ревью #273)' do
      expect(past_viewing.confirm!).to be(false)
      expect(past_viewing.errors[:preferred_date]).to include('не может быть в прошлом')
      expect(past_viewing.reload.status).to eq('pending')
    end

    it 'восстановление прошедшего cancelled в активный статус отклоняется' do
      past_viewing.update!(status: 'cancelled', cancelled_at: Time.current)

      expect(past_viewing.update(status: 'pending')).to be(false)
      expect(past_viewing.errors[:preferred_date]).to include('не может быть в прошлом')
    end

    it 'восстановление будущего cancelled проходит (дата и слот валидны)' do
      viewing = build_viewing(status: 'cancelled').tap(&:save!)

      expect(viewing.update(status: 'pending')).to be(true)
    end
  end

  describe 'прямое присваивание scheduled_at (блокер 2 ревью #273)' do
    it 'ends_at следует за новым началом по duration' do
      viewing = build_viewing.tap(&:save!) # 10:00–11:00 завтра

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)
    end

    it 'ручная длительность сохраняется при прямом переносе' do
      viewing = build_viewing.tap(&:save!)
      viewing.update_columns(ends_at: viewing.scheduled_at + 90.minutes)
      viewing.reload

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours + 30.minutes)
    end

    it 'прямой перенос на занятый слот отклоняется' do
      build_viewing(preferred_time: '12:00').tap(&:save!)
      viewing = build_viewing(preferred_time: '10:00').tap(&:save!)

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
      expect(viewing).not_to be_valid
      expect(viewing.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
    end
  end

  describe 'повторная валидация и retry переноса (блокер 1 ревью раунда 3)' do
    it 'повторная валидация не растягивает автоматический ends_at' do
      viewing = build_viewing.tap(&:save!) # 10:00–11:00 завтра

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)

      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)

      viewing.save!
      expect(viewing.reload.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)
    end

    it 'retry после неудачного переноса собирает ends_at от нового начала' do
      build_viewing(preferred_time: '12:00').tap(&:save!)
      viewing = build_viewing(preferred_time: '10:00').tap(&:save!)

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours # занято
      expect(viewing).not_to be_valid

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 14.hours # свободно
      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 15.hours)
    end

    it 'ручная длительность стабильна при повторной валидации' do
      viewing = build_viewing.tap(&:save!)
      viewing.update_columns(ends_at: viewing.scheduled_at + 90.minutes)
      viewing.reload

      viewing.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
      2.times { expect(viewing).to be_valid }
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours + 30.minutes)
    end
  end

  describe 'правка границ и объекта без смены начала (блокер 2 ревью раунда 3)' do
    it 'явный update(ends_at:) уважается и не перетирается сборкой' do
      viewing = build_viewing.tap(&:save!) # 10:00–11:00 завтра

      expect(viewing.update(ends_at: viewing.scheduled_at + 3.hours)).to be(true)
      expect(viewing.reload.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)
    end

    it 'удлинение ends_at до пересечения с соседним показом отклоняется' do
      viewing = build_viewing.tap(&:save!)              # 10:00–11:00
      build_viewing(preferred_time: '11:30').tap(&:save!) # 11:30–12:30

      expect(viewing.update(ends_at: viewing.scheduled_at + 2.hours)).to be(false)
      expect(viewing.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
    end

    it 'перенос на другой объект с занятым слотом отклоняется' do
      other_property = create(:property)
      build_viewing(property: other_property, preferred_time: '10:00').tap(&:save!)
      viewing = build_viewing.tap(&:save!)

      expect(viewing.update(property: other_property)).to be(false)
      expect(viewing.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
    end

    it 'перенос на свободный объект проходит' do
      other_property = create(:property)
      viewing = build_viewing.tap(&:save!)

      expect(viewing.update(property: other_property)).to be(true)
    end

    it 'правка границ прошедшего показа не упирается в date_not_in_past' do
      past_start = Date.yesterday.in_time_zone + 10.hours
      viewing = build_viewing(preferred_date: Date.current, preferred_time: '10:00')
      viewing.scheduled_at = past_start
      viewing.ends_at = past_start + 60.minutes
      viewing.save!(validate: false)

      expect(viewing.update(ends_at: past_start + 90.minutes)).to be(true)
    end
  end

  describe 'retry новой записи и инвариант границ (блокеры раунда 4)' do
    it 'retry новой записи после неудачной валидации пересобирает ends_at' do
      build_viewing(preferred_time: '12:00').tap(&:save!) # занятый слот
      viewing = build_viewing(preferred_time: '12:00')

      expect(viewing).not_to be_valid
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)

      viewing.preferred_time = '14:00'
      expect(viewing).to be_valid
      expect(viewing.scheduled_at).to eq(Date.tomorrow.in_time_zone + 14.hours)
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 15.hours)
    end

    it 'явное раннее ends_at отклоняется' do
      viewing = build_viewing.tap(&:save!)

      expect(viewing.update(ends_at: viewing.scheduled_at - 30.minutes)).to be(false)
      expect(viewing.errors[:ends_at]).to include('должно быть позже начала показа')
    end

    it 'равный конец и начало отклоняются' do
      viewing = build_viewing.tap(&:save!)

      expect(viewing.update(ends_at: viewing.scheduled_at)).to be(false)
      expect(viewing.errors[:ends_at]).to include('должно быть позже начала показа')
    end

    it 'новая запись с явным инвертированным ends_at отклоняется' do
      viewing = build_viewing(ends_at: Date.tomorrow.in_time_zone + 9.hours + 30.minutes)

      expect(viewing).not_to be_valid
      expect(viewing.errors[:ends_at]).to include('должно быть позже начала показа')
    end
  end

  describe 'перенос слота (блокер 2 ревью #272)' do
    it 'ends_at пересчитывается вместе с scheduled_at' do
      viewing = build_viewing.tap(&:save!) # 10:00–11:00 завтра

      viewing.preferred_time = '12:00'
      expect(viewing).to be_valid
      expect(viewing.scheduled_at).to eq(Date.tomorrow.in_time_zone + 12.hours)
      expect(viewing.ends_at).to eq(Date.tomorrow.in_time_zone + 13.hours)
    end

    it 'вручную выставленный ends_at перенос не затирает' do
      viewing = build_viewing.tap(&:save!)
      viewing.update_columns(ends_at: viewing.scheduled_at + 90.minutes)
      viewing.reload

      viewing.preferred_time = '12:00'
      expect(viewing).to be_valid
      expect(viewing.ends_at).to eq(viewing.scheduled_at + 90.minutes)
    end

    it 'перенос на занятый слот отклоняется' do
      build_viewing(preferred_time: '12:00').tap(&:save!)
      viewing = build_viewing(preferred_time: '10:00').tap(&:save!)

      viewing.preferred_time = '12:00'
      expect(viewing).not_to be_valid
      expect(viewing.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
    end

    it 'подтверждение показа на занятом слоте отклоняется (активация слота)' do
      build_viewing(preferred_time: '12:00', status: 'confirmed').tap(&:save!)
      # Пересекающийся pending-показ заводим в обход валидаций (колонки
      # напрямую: save(validate: false) пропускает и сборку scheduled_at).
      viewing = build_viewing(preferred_time: '12:00', status: 'pending').tap do |v|
        v.scheduled_at = Date.tomorrow.in_time_zone + 12.hours
        v.ends_at = v.scheduled_at + 60.minutes
        v.save!(validate: false)
      end

      expect(viewing.confirm!).to be(false)
      expect(viewing.errors[:preferred_time]).to include('уже занято. Пожалуйста, выберите другое время')
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
