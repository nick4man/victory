# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::TutorialRenderer do
  let(:agent) do
    TelegramUser.create!(tg_user_id: 141_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 141_001)
  end
  let(:director) do
    TelegramUser.create!(tg_user_id: 141_002, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 141_002)
  end

  def buttons(result)
    result.keyboard[:inline_keyboard].flatten
  end

  describe 'заголовок и нумерация' do
    it 'считает знаменатель по доступным роли урокам, а не по всему курсу' do
      agent_total = Telegram::WorkBot::TutorialLessons.visible_for(agent).size
      director_total = Telegram::WorkBot::TutorialLessons.visible_for(director).size

      expect(described_class.call(tg_user: agent).markdown).to include("Урок 1 из #{agent_total}")
      expect(described_class.call(tg_user: director).markdown).to include("Урок 1 из #{director_total}")
      expect(agent_total).to be < director_total
    end

    it 'показывает заголовок и тело запрошенного урока' do
      lesson = Telegram::WorkBot::TutorialLessons.visible_for(director)[1]

      markdown = described_class.call(tg_user: director, index: 1).markdown

      expect(markdown).to include(lesson[:title])
      expect(markdown).to include(lesson[:body].lines.first.strip)
      expect(markdown).to include('Урок 2 из')
    end
  end

  describe 'клавиатура' do
    it 'на первом уроке нет кнопки «Назад»' do
      texts = buttons(described_class.call(tg_user: director, index: 0)).map { |b| b[:text] }

      expect(texts).to include('Далее ▶️')
      expect(texts).not_to include('◀️ Назад')
    end

    it 'в середине курса ведёт и вперёд, и назад' do
      result = described_class.call(tg_user: director, index: 2)
      data = buttons(result).map { |b| b[:callback_data] }

      expect(data).to contain_exactly('tutorial:go:1', 'tutorial:go:3')
    end

    it 'на последнем уроке предлагает «Готово» вместо «Далее»' do
      last = Telegram::WorkBot::TutorialLessons.visible_for(director).size - 1
      texts = buttons(described_class.call(tg_user: director, index: last)).map { |b| b[:text] }

      expect(texts).to include('✅ Готово')
      expect(texts).not_to include('Далее ▶️')
    end

    it 'все callback_data укладываются в лимит Telegram (64 байта)' do
      Telegram::WorkBot::TutorialLessons.visible_for(director).each_index do |i|
        buttons(described_class.call(tg_user: director, index: i)).each do |btn|
          expect(btn[:callback_data]).to match(/\Atutorial:/)
          expect(btn[:callback_data].bytesize).to be <= 64
        end
      end
    end
  end

  describe 'выход за границы списка' do
    it 'индекс больше последнего показывает последний урок' do
      last = Telegram::WorkBot::TutorialLessons.visible_for(agent).size

      result = described_class.call(tg_user: agent, index: 99)

      expect(result.markdown).to include("Урок #{last} из #{last}")
      expect(buttons(result).map { |b| b[:text] }).to include('✅ Готово')
    end

    it 'отрицательный индекс показывает первый урок' do
      expect(described_class.call(tg_user: agent, index: -5).markdown).to include('Урок 1 из')
    end

    it 'без доступных уроков возвращает пояснение и пустую клавиатуру' do
      result = described_class.call(tg_user: nil)

      expect(result.markdown).to include('недоступно')
      expect(result.keyboard).to eq({ inline_keyboard: [] })
    end
  end

  describe '.finish' do
    it 'снимает клавиатуру и отправляет к шпаргалке' do
      result = described_class.finish(tg_user: director)

      expect(result.markdown).to include('/cheatsheet')
      expect(result.keyboard).to eq({ inline_keyboard: [] })
    end
  end
end
