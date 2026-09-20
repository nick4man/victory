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
    expect(card.notes.last.note).to include('Согласована правка', '79101112233', '79209998877')
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
end
