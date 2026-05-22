# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::DirectorSelfAudit do
  let(:director) do
    TelegramUser.create!(tg_user_id: 9_001, tg_username: 'oks07victory', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active')
  end
  let(:agent) do
    TelegramUser.create!(tg_user_id: 9_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end

  describe '.schema' do
    it 'expose tool name + required period parameter' do
      schema = described_class.schema
      expect(schema[:function][:name]).to eq('director_self_audit')
      expect(schema[:function][:parameters][:required]).to include('period')
    end
  end

  describe '.call' do
    context 'period=today, нет данных' do
      it 'возвращает структуру со счётчиками 0 и пустыми items' do
        res = described_class.call({ period: 'today' }, asked_by: director)
        expect(res[:tasks_created][:count]).to eq(0)
        expect(res[:tasks_created][:items]).to eq([])
        expect(res[:leads_assigned][:count]).to eq(0)
        expect(res[:period_label]).to eq('сегодня')
      end
    end

    context 'period=today с созданной задачей' do
      before do
        Task.create!(title: 'Позвонить Анне', assignee_id: agent.id, created_by_id: director.id,
                     status: 'open', kind: 'call', priority: 'normal', assigned_at: Time.current)
      end

      it 'tasks_created.count=1 и item содержит title + assignee.mention' do
        res = described_class.call({ period: 'today', category: 'tasks_created' }, asked_by: director)
        expect(res[:tasks_created][:count]).to eq(1)
        expect(res[:tasks_created][:items].first[:title]).to eq('Позвонить Анне')
        expect(res[:tasks_created][:items].first[:assignee]).to eq(agent.mention)
      end

      it "category=all включает все 3 секции" do
        res = described_class.call({ period: 'today', category: 'all' }, asked_by: director)
        expect(res).to have_key(:tasks_created)
        expect(res).to have_key(:leads_routed)
        expect(res).to have_key(:leads_assigned)
      end
    end

    context 'agent caller просит чужой self-audit' do
      it 'silent self-only (target = caller, не Оксана)' do
        Task.create!(title: 'своя задача agent', assignee_id: agent.id, created_by_id: agent.id,
                     status: 'open', kind: 'admin', priority: 'normal', assigned_at: Time.current)

        res = described_class.call({ period: 'today', staff_username: 'oks07victory' }, asked_by: agent)
        expect(res[:target_mention]).to eq(agent.mention)
        expect(res[:tasks_created][:count]).to eq(1)
      end
    end

    context 'period=custom с корректными dd.MM.yy' do
      it 'парсит from/to и возвращает label с диапазоном' do
        res = described_class.call(
          { period: 'custom', from_date: '01.05.26', to_date: '15.05.26', category: 'tasks_created' },
          asked_by: director
        )
        expect(res[:period_label]).to eq('01.05.26–15.05.26')
        expect(res[:tasks_created][:count]).to eq(0)
      end
    end

    context 'period=custom с битыми датами' do
      it 'возвращает error: bad_period' do
        res = described_class.call(
          { period: 'custom', from_date: 'qweqweqwe', to_date: '01.05.26', category: 'tasks_created' },
          asked_by: director
        )
        expect(res[:error]).to eq('bad_period')
      end
    end

    context 'без asked_by и без caller_tg_user_id' do
      it 'возвращает error: caller_unknown' do
        res = described_class.call({ period: 'today' })
        expect(res[:error]).to eq('caller_unknown')
      end
    end

    # Phase 15 — agency_wide mode для director DM control panel
    context 'mode=agency_wide (manager+)' do
      before do
        # Задача от agent (не director'a) — должна попасть в agency-wide view
        Task.create!(title: 'agent task', assignee_id: agent.id, created_by_id: agent.id,
                     status: 'open', kind: 'admin', priority: 'normal', assigned_at: Time.current)
      end

      it 'возвращает агрегаты ВСЕХ staff (без фильтра по конкретному user)' do
        res = described_class.call({ period: 'today', mode: 'agency_wide', category: 'tasks_created' }, asked_by: director)
        expect(res[:mode]).to eq('agency_wide')
        expect(res[:target_mention]).to eq('АН Виктори (все сотрудники)')
        expect(res[:tasks_created][:count]).to eq(1)
        # Item должен иметь creator (кто создал) — это новый ключ для agency mode
        expect(res[:tasks_created][:items].first[:creator]).to eq(agent.mention)
      end

      it 'agent → error forbidden (mode=agency_wide manager+ only)' do
        res = described_class.call({ period: 'today', mode: 'agency_wide' }, asked_by: agent)
        expect(res[:error]).to eq('forbidden')
      end
    end
  end
end
