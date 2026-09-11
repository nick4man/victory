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
      run('edinstvo', 10)

      expect(described_class.silent_sources('erz' => 5, 'edinstvo' => 9)).to eq(['erz'])
    end

    it 'источник, молчащий третью неделю подряд, продолжает считаться молчащим (уровневое правило, круг правок 2)' do
      run('erz', 40, days_ago: 22) # неделя 1 — здоровый прогон
      run('erz', 0, days_ago: 15)  # неделя 2 — обвал, фронтовое правило поймало бы именно здесь
      run('erz', 0, days_ago: 8)   # неделя 3 — по-прежнему мёртв

      # Неделя 4, снова 0. Фронтовое правило само по себе МОЛЧАЛО бы:
      # previous_run_count = 0 (неделя 3), 0 * SILENCE_RATIO = 0, и никакое
      # current не может быть < 0 — источник сравнивался бы сам с собой на
      # дне. Уровневое правило обязано сработать снова, а не один раз.
      expect(described_class.silent_sources('erz' => 0)).to include('erz')
    end

    it 'источник, мёртвый с рождения (count всегда 0), ловится начиная со второго прогона' do
      # Первый прогон в жизни источника — истории нет вовсе, сравнивать
      # не с чем (правило «первый раз в жизни»), тревоги быть не должно.
      expect(described_class.silent_sources('newcomer' => 0)).to be_empty

      run('newcomer', 0) # первый реальный прогон, зафиксированный в истории

      # Второй прогон — история уже есть (пусть и из одной нулевой
      # строки), и count снова 0. Фронтовое правило здесь бессильно:
      # previous_run_count = 0, экспектед.zero? отсекает его сразу же —
      # источник, мёртвый с рождения, никогда не проходил через МОМЕНТ
      # перехода из «жив» в «мёртв». Только уровневое правило это ловит.
      expect(described_class.silent_sources('newcomer' => 0)).to include('newcomer')
    end

    it 'источник с непустой, но ненулевой историей и ненулевым текущим count не считается молчащим уровнево' do
      run('erz', 2) # маленький, но не ноль
      expect(described_class.silent_sources('erz' => 2)).to be_empty
    end
  end

  describe '.call' do
    it 'включает счётчики каждого источника и дату в формате dd.MM.yy' do
      text = described_class.call('erz' => 3, 'edinstvo' => 7)

      expect(text).to include(Time.zone.today.strftime('%d.%m.%y'))
      expect(text).to include('erz: 3')
      expect(text).to include('edinstvo: 7')
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
