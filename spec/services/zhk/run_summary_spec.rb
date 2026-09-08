# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::RunSummary do
  # Прогон-предок: пишем строку `ZhkIngestRun` напрямую (в обход `.call`),
  # чтобы проверять `silent_sources`/`.call` изолированно от их
  # собственного побочного эффекта — записи ТЕКУЩЕГО прогона.
  def run(source, count, days_ago: 8)
    ZhkIngestRun.create!(source: source, count: count, ran_at: days_ago.days.ago)
  end

  describe '.silent_sources' do
    it 'называет источник молчащим, когда он отдал кратно меньше предыдущего прогона' do
      run('erz', 40)

      expect(described_class.silent_sources('erz' => 5)).to include('erz')
    end

    it 'не молчит, когда объём в норме относительно предыдущего прогона' do
      run('erz', 40)

      expect(described_class.silent_sources('erz' => 38)).to be_empty
    end

    it 'не считает молчащим источник, у которого ещё не было ни одного прогона' do
      expect(described_class.silent_sources('newcomer' => 1)).to be_empty
    end

    it 'сравнивает с ПОСЛЕДНИМ прогоном, а не с более старым' do
      run('erz', 40, days_ago: 30)
      run('erz', 5, days_ago: 8) # последний прогон — уже маленький сам по себе

      # Если бы сравнение шло со старым прогоном (40), 5 < 40*0.3=12 → silent.
      # Правильное сравнение — с последним (5): 5 < 5*0.3=1.5 → не молчит.
      expect(described_class.silent_sources('erz' => 5)).to be_empty
    end

    it 'ровно на границе порога источник ещё не молчащий (строгое «меньше», не «не больше»)' do
      run('erz', 10) # порог — ровно 10 * 0.3 = 3.0

      expect(described_class.silent_sources('erz' => 3)).to be_empty
    end

    it 'молчащим считается только тот источник, у которого действительно провал, а не сосед' do
      run('erz', 40)
      run('developer_site', 10)

      expect(described_class.silent_sources('erz' => 5, 'developer_site' => 9)).to eq(['erz'])
    end
  end

  describe '.call' do
    it 'включает счётчики каждого источника и дату в формате dd.MM.yy' do
      text = described_class.call('erz' => 3, 'developer_site' => 7)

      expect(text).to include(Time.zone.today.strftime('%d.%m.%y'))
      expect(text).to include('erz: 3')
      expect(text).to include('developer_site: 7')
    end

    it 'экранирует имя источника — сообщение уходит в Telegram с parse_mode HTML' do
      text = described_class.call('<b>erz</b>' => 3)

      expect(text).not_to include('<b>erz</b>')
      expect(text).to include('&lt;b&gt;erz&lt;/b&gt;')
    end

    it 'отмечает молчащий источник пометкой, а не молчит о нём' do
      run('erz', 40)

      text = described_class.call('erz' => 1)

      expect(text).to include('erz')
      expect(text).to match(/молч/i)
    end

    it 'не добавляет пометку про молчание, когда молчащих источников нет' do
      text = described_class.call('erz' => 5)

      expect(text).not_to match(/молч/i)
    end

    it 'записывает текущий прогон в журнал, чтобы следующий сравнивался с НИМ' do
      described_class.call('erz' => 40)

      expect(ZhkIngestRun.for_source('erz').count).to eq(1)
      expect(described_class.silent_sources('erz' => 5)).to include('erz')
    end

    it 'не сравнивает источник этого же вызова сам с собой' do
      # Если бы запись прогона происходила ДО расчёта silent_sources
      # внутри одного и того же call, source сравнивался бы с собственным
      # только что записанным числом — 40 никогда не показался бы
      # молчащим сам себе.
      text = described_class.call('erz' => 40)

      expect(text).not_to match(/молч/i)
    end
  end
end
