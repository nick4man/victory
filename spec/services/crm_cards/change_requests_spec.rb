# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::ChangeRequests do
  let(:notifier) { instance_double(CrmCards::Notifier, change_requested: nil, change_decided: nil) }
  let(:service) { described_class.new(notifier: notifier) }

  let!(:agent) { crm_staff(tg_user_id: 98_801, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_802, username: 'oksana', position: '89884', role: 'director') }
  let(:card) do
    CrmCard.create!(kind: 'lead', author: agent, status: 'exported', crm_id: '4455', export_mode: 'api',
                    exported_at: Time.current,
                    payload: { 'name' => 'Анна Смирнова', 'phone' => '79101112233', 'action' => 'sale',
                               'object_type' => 'flat', 'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' })
  end

  before { stub_crm_positions }

  it 'правка опубликованной карточки не меняет поле сразу — уходит модератору' do
    result = service.open!(card, actor: agent, field: 'phone', value: '79209998877')

    expect(result).to be_ok
    expect(card.reload.payload['phone']).to eq('79101112233')
    expect(notifier).to have_received(:change_requested).with(result.request, moderators: [director])
  end

  it 'одобрение меняет поле и оставляет след в CRM заметкой' do
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request

    expect(service.approve!(request, actor: director)).to be_ok
    expect(card.reload.payload['phone']).to eq('79209998877')
    # Значения в заметке — как в карточке, а не машинные: коллега в CRM читает её глазами.
    expect(card.notes.last.note).to include('Согласована правка', '+7 910 111-22-33', '+7 920 999-88-77')
  end

  it 'отклонение поле не трогает и требует объяснения' do
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request

    expect(service.reject!(request, actor: director, comment: ' ').error).to include('Нужен комментарий')
    expect(service.reject!(request, actor: director, comment: 'клиент подтвердил старый номер')).to be_ok
    expect(card.reload.payload['phone']).to eq('79101112233')
    expect(request.reload).to be_status_rejected
  end

  it 'решение по заявке принимает модератор, а не автор' do
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request

    expect(service.approve!(request, actor: agent).error).to include('модератор')
    expect(card.reload.payload['phone']).to eq('79101112233')
  end

  it 'две открытые заявки по одному полю не заводятся' do
    service.open!(card, actor: agent, field: 'phone', value: '79209998877')

    expect(service.open!(card, actor: agent, field: 'phone', value: '79205554433').error)
      .to include('уже есть заявка')
  end

  it 'неопубликованная карточка правится обычным путём, без заявки' do
    draft = CrmCard.create!(kind: 'lead', author: agent, payload: { 'name' => 'Анна' })

    expect(service.open!(draft, actor: agent, field: 'name', value: 'Анна Смирнова').error)
      .to include('ещё не в CRM')
  end

  it 'дважды решение по одной заявке не принимается' do
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request
    service.approve!(request, actor: director)

    expect(service.approve!(request.reload, actor: director).error).to include('уже принято')
  end

  it 'одобрение двух правок подряд не теряет первую' do
    phone_req = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request
    name_req = service.open!(card, actor: agent, field: 'name', value: 'Анна Петрова').request

    service.approve!(phone_req, actor: director)
    service.approve!(name_req.reload, actor: director)

    expect(card.reload.payload).to include('phone' => '79209998877', 'name' => 'Анна Петрова')
  end

  it 'после правки машинная проверка пересчитывается, а не остаётся вчерашней' do
    card.update!(check_errors: [], checked_at: 1.day.ago)
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request

    expect { service.approve!(request, actor: director) }
      .to change { card.reload.checked_at }
    expect(card.transitions.last.comment).to include('правка поля')
  end

  it 'значения в заметке человеческие, а не машинные коды' do
    request = service.open!(card, actor: agent, field: 'action', value: 'rent').request
    service.approve!(request, actor: director)

    note = card.reload.notes.last.note
    expect(note).to include('Аренда')
    expect(note).not_to include('«rent»')
  end

  it 'карточку песочницы в рабочем боте не решают' do
    card.update!(sandbox: true)
    request = service.open!(card, actor: agent, field: 'phone', value: '79209998877').request

    expect(service.approve!(request, actor: director).error).to include('песочниц')
    expect(card.reload.payload['phone']).to eq('79101112233')
  end
end
