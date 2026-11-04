# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Notes do
  let(:notifier) { instance_double(CrmCards::Notifier, exported: nil) }
  let!(:agent) { crm_staff(tg_user_id: 98_701, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_702, username: 'oksana', position: '89884', role: 'director') }
  let(:card) { CrmCard.create!(kind: 'lead', author: agent, payload: { 'name' => 'Анна' }) }

  before { stub_crm_positions }

  it 'заметка добавляется без модерации и видна сразу' do
    result = described_class.add!(card, actor: agent, text: 'Созвонились, смотрит квартиру в субботу')

    expect(result).to be_ok
    expect(card.reload.notes.count).to eq(1)
    expect(card.notes.last.note).to include('в субботу')
  end

  it 'прежние записи не переписываются — история накапливается' do
    described_class.add!(card, actor: agent, text: 'Первый звонок, бюджет 6 млн')
    described_class.add!(card, actor: agent, text: 'Второй звонок, бюджет вырос до 7 млн')

    expect(card.reload.notes.recent.map(&:note)).to eq(['Второй звонок, бюджет вырос до 7 млн',
                                                        'Первый звонок, бюджет 6 млн'])
  end

  it 'карточка уже в CRM — заметка уходит туда же' do
    card.update!(status: 'exported', crm_id: '4455', export_mode: 'api', exported_at: Time.current)

    expect { described_class.add!(card, actor: agent, text: 'Клиент просит перенести показ') }
      .to have_enqueued_job(TopnlabNotePushJob)
    expect(card.reload.notes.last.crm_entity_type).to eq('order')
  end

  it 'карточка ещё не в CRM — в CRM ничего не шлём' do
    expect { described_class.add!(card, actor: agent, text: 'Пока только первый контакт') }
      .not_to have_enqueued_job(TopnlabNotePushJob)
  end

  it 'песочница в CRM не пишет даже с номером' do
    card.update!(sandbox: true, status: 'exported', crm_id: "TEST-#{card.id}")

    expect { described_class.add!(card, actor: agent, text: 'Проверка песочницы') }
      .not_to have_enqueued_job(TopnlabNotePushJob)
  end

  it 'чужой карточке заметку не допишешь' do
    stranger = crm_staff(tg_user_id: 98_703, username: 'petr')

    expect(described_class.add!(card, actor: stranger, text: 'Мимо проходил').error).to include('кто ведёт клиента')
  end

  it 'модератор дописать может' do
    expect(described_class.add!(card, actor: director, text: 'Проверил, всё на месте')).to be_ok
  end

  it 'пустая заметка не сохраняется' do
    expect(described_class.add!(card, actor: agent, text: ' ').error).to include('Слишком коротко')
    expect(card.reload.notes).to be_empty
  end

  it 'заметки, написанные до CRM, уходят туда при выгрузке' do
    described_class.add!(card, actor: agent, text: 'Первый звонок, бюджет 6 млн')
    described_class.add!(card, actor: agent, text: 'Показ в субботу')
    card.update!(status: 'exporting')

    expect { CrmCards::Workflow.new(notifier: notifier).record_export!(card, crm_id: '4455', mode: 'api') }
      .to have_enqueued_job(TopnlabNotePushJob).twice
    expect(card.reload.notes.map(&:crm_entity_type).uniq).to eq(['order'])
  end

  it 'автор заметки без учётки в CRM не превращается в чужого сотрудника' do
    # Сотрудник без учётки в CRM: раньше именно его подставляло find_by(crm_user_id: nil).
    User.create!(email: 'someone@victory62.org', first_name: 'Чужой', last_name: 'Сотрудник',
                 role: 'client', password: 'secret123456')
    note = described_class.add!(card, actor: agent, text: 'Из песочницы, без учётки').note
    note.update_columns(user_id: nil, crm_user_id: nil)

    expect(note.reload.author_name).to eq('Сотрудник CRM')
  end

  it 'длинная заметка не раздувает карточку сверх лимита Telegram' do
    described_class.add!(card, actor: agent, text: 'я' * 2000)

    expect(CrmCards::CardView.render(card.reload, viewer: agent)[:text].length).to be < 4096
  end
end
