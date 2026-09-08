# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::RunSummary do
  def observation(source, days_ago)
    ZhkObservation.create!(source: source, external_id: "#{source}:#{SecureRandom.hex(4)}",
                           fetched_at: days_ago.days.ago, payload: {},
                           digest: SecureRandom.hex(32))
  end

  describe '.silent_sources' do
    it 'называет источник молчащим, когда он отдал кратно меньше обычного' do
      5.times { observation('erz', 9) }

      expect(described_class.silent_sources('erz' => 1)).to include('erz')
    end

    it 'молчит, когда объём в норме' do
      5.times { observation('erz', 9) }

      expect(described_class.silent_sources('erz' => 5)).to be_empty
    end

    it 'не считает молчащим источник, который раньше не появлялся' do
      expect(described_class.silent_sources('newcomer' => 1)).to be_empty
    end

    it 'не учитывает наблюдения старше прошлой недели — сравнение не «со всех времён»' do
      5.times { observation('erz', 20) } # за пределами окна 7-14 дней

      expect(described_class.silent_sources('erz' => 1)).to be_empty
    end

    it 'не учитывает наблюдения этого же прогона (моложе 7 дней) как «прошлую неделю»' do
      5.times { observation('erz', 1) }

      expect(described_class.silent_sources('erz' => 1)).to be_empty
    end

    it 'ровно на границе порога источник ещё не молчащий (строгое «меньше», не «не больше»)' do
      10.times { observation('erz', 9) } # ожидание 10, порог — ровно 10 * 0.3 = 3.0

      expect(described_class.silent_sources('erz' => 3)).to be_empty
    end

    it 'ровно 7 дней назад — ещё «прошлая неделя», 6 дней назад — уже «эта»' do
      observation('erz', 7)
      4.times { observation('erz', 6) }

      # Если бы окно ошибочно захватывало и 6-дневные наблюдения,
      # previous_week_count был бы 5, а не 1, и 1 < 5 * 0.3 стало бы true.
      expect(described_class.silent_sources('erz' => 1)).to be_empty
    end
  end

  describe '.call' do
    it 'включает счётчики каждого источника и дату в формате dd.MM.yy' do
      text = described_class.call('erz' => 3, 'developer_site' => 7)

      expect(text).to include(Time.zone.today.strftime('%d.%m.%y'))
      expect(text).to include('erz: 3')
      expect(text).to include('developer_site: 7')
    end

    it 'отмечает молчащий источник пометкой, а не молчит о нём' do
      5.times { observation('erz', 9) }

      text = described_class.call('erz' => 1)

      expect(text).to include('erz')
      expect(text).to match(/молч/i)
    end

    it 'не добавляет пометку про молчание, когда молчащих источников нет' do
      text = described_class.call('erz' => 5)

      expect(text).not_to match(/молч/i)
    end
  end
end
