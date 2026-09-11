# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::TutorialLessons do
  let(:agent) do
    TelegramUser.create!(tg_user_id: 140_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 140_001)
  end
  let(:manager) do
    TelegramUser.create!(tg_user_id: 140_002, tg_username: 'nick', first_name: 'Николай',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 140_002)
  end
  let(:director) do
    TelegramUser.create!(tg_user_id: 140_003, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: false, status: 'active', dm_chat_id: 140_003)
  end

  describe '.visible_for' do
    it 'агенту показывает только staff-уроки' do
      levels = described_class.visible_for(agent).map { |l| l[:min_level] }

      expect(levels.uniq).to eq([:staff])
      expect(levels).not_to be_empty
    end

    it 'руководителю добавляет manager-уроки, но не директорские' do
      levels = described_class.visible_for(manager).map { |l| l[:min_level] }

      expect(levels).to include(:staff, :manager)
      expect(levels).not_to include(:director)
    end

    it 'директору показывает весь курс, включая голосовые задачи' do
      keys = described_class.visible_for(director).map { |l| l[:key] }

      expect(keys).to eq(described_class::LESSONS.map { |l| l[:key] })
      expect(keys).to include('voice')
    end

    it 'директору без is_manager отдаёт и manager-уроки (role, а не legacy-флаг)' do
      keys = described_class.visible_for(director).map { |l| l[:key] }

      expect(director.is_manager).to be_falsey
      expect(keys).to include('assign')
    end

    it 'незарегистрированному (nil) не показывает ничего' do
      expect(described_class.visible_for(nil)).to be_empty
    end

    it 'сохраняет порядок уроков' do
      visible = described_class.visible_for(director)

      expect(visible).to eq(described_class::LESSONS)
    end
  end

  describe 'содержание уроков' do
    it 'у каждого урока есть непустые ключ, заголовок и тело' do
      described_class::LESSONS.each do |lesson|
        expect(lesson[:key]).to be_present
        expect(lesson[:title]).to be_present
        expect(lesson[:body]).to be_present
      end
    end

    it 'ключи уникальны' do
      keys = described_class::LESSONS.map { |l| l[:key] }

      expect(keys.uniq.size).to eq(keys.size)
    end

    it 'уровень доступа у каждого урока — известный' do
      levels = described_class::LESSONS.map { |l| l[:min_level] }

      expect(levels - %i[staff manager director]).to be_empty
    end

    it 'карточка умещается в одно сообщение Telegram (лимит 4096)' do
      described_class::LESSONS.each do |lesson|
        expect(lesson[:body].length).to be < 3500, "урок #{lesson[:key]} слишком длинный"
      end
    end

    # Анти-дрейф: обучение не должно рассказывать про команды, которых в боте нет.
    it 'все упомянутые команды существуют в Router::COMMANDS' do
      known = Telegram::WorkBot::Router::COMMANDS.keys

      described_class::LESSONS.each do |lesson|
        plain = lesson[:body].gsub(/<[^>]+>/, ' ')
        mentioned = plain.scan(%r{(?<![\w/])/[a-z_]{2,}}).uniq

        unknown = mentioned - known

        expect(unknown).to be_empty, "урок #{lesson[:key]} ссылается на неизвестные команды: #{unknown.join(', ')}"
      end
    end
  end
end
