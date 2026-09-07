# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::TelegramReachability do
  # Расклад повторяет прод на 09.08.26: из четырёх агентов бот может написать
  # только одному, и по трём разным причинам не может остальным.
  let(:tg_ok) do
    TelegramUser.create!(tg_user_id: 900_001, tg_username: 'nadya', first_name: 'Надежда',
                         email: 'nadya@victory62.test', status: 'active',
                         dm_chat_id: 111, role: 'agent')
  end
  let(:tg_no_dm) do
    TelegramUser.create!(tg_user_id: 900_002, tg_username: 'irina', first_name: 'Ирина',
                         email: 'irina@victory62.test', status: 'active',
                         dm_chat_id: nil, role: 'agent')
  end
  let(:tg_inactive) do
    TelegramUser.create!(tg_user_id: 900_003, tg_username: 'dasha', first_name: 'Дарья',
                         email: 'dasha@victory62.test', status: 'inactive',
                         dm_chat_id: 222, role: 'agent')
  end

  def agent(telegram_user)
    create(:user, role: :agent, telegram_user: telegram_user)
  end

  describe '.for' do
    it 'считает достижимым связанного агента с открытой личкой' do
      expect(described_class.for(agent(tg_ok))).to eq(:ok)
    end

    it 'отличает несвязанного агента' do
      expect(described_class.for(agent(nil))).to eq(:no_link)
    end

    it 'отличает закрытую личку от отсутствия связи' do
      expect(described_class.for(agent(tg_no_dm))).to eq(:no_dm)
    end

    it 'отличает неактивированный аккаунт' do
      expect(described_class.for(agent(tg_inactive))).to eq(:inactive)
    end

    # Порядок проверок: неактивный аккаунт с закрытой личкой должен назваться
    # неактивным. Иначе директор пойдёт просить человека «написать боту», хотя
    # проблема на шаг раньше.
    it 'называет самую раннюю причину, а не последнюю' do
      tg = TelegramUser.create!(tg_user_id: 900_004, tg_username: 'both', first_name: 'Оба',
                                status: 'inactive', dm_chat_id: nil, role: 'agent')
      expect(described_class.for(agent(tg))).to eq(:inactive)
    end

    it 'не падает на nil' do
      expect(described_class.for(nil)).to eq(:no_link)
    end
  end

  describe '.report' do
    it 'раскладывает агентов по причинам' do
      ok = agent(tg_ok)
      no_dm = agent(tg_no_dm)
      inactive = agent(tg_inactive)
      no_link = agent(nil)

      report = described_class.report([ok, no_dm, inactive, no_link])

      expect(report[:ok]).to eq([ok])
      expect(report[:no_dm]).to eq([no_dm])
      expect(report[:inactive]).to eq([inactive])
      expect(report[:no_link]).to eq([no_link])
    end

    # Пустые ключи нужны вызывающему: отчёт директору перечисляет все причины,
    # включая те, по которым сейчас никого нет.
    it 'возвращает все причины даже когда часть пуста' do
      expect(described_class.report([]).keys).to match_array(described_class::REASONS)
    end
  end

  describe '.explain' do
    it 'объясняет причину по-русски' do
      expect(described_class.explain(:no_dm)).to include('написать боту первым')
    end
  end

  describe 'User.reachable_in_tg' do
    it 'отбирает только тех, кому бот физически может написать' do
      ok = agent(tg_ok)
      agent(tg_no_dm)
      agent(tg_inactive)
      agent(nil)

      expect(User.reachable_in_tg).to contain_exactly(ok)
    end
  end

  describe 'связь один-к-одному' do
    it 'не даёт привязать один телеграм ко второму сотруднику' do
      agent(tg_ok)
      expect { agent(tg_ok) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'даёт обратную ссылку с TelegramUser на сотрудника' do
      user = agent(tg_ok)
      expect(tg_ok.reload.user).to eq(user)
    end
  end
end
