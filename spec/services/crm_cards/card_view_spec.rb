# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::CardView do
  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_501, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_502, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, checked_at: Time.current,
                    payload: { 'name' => 'Анна <b>', 'phone' => '79101234567', 'action' => 'sale',
                               'object_type' => 'flat', 'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' })
  end

  def callbacks(view)
    view[:keyboard].flatten.map { |b| b[:callback_data] }
  end

  it 'текст: поля по-русски, телефон читаемо, пользовательский ввод экранирован' do
    text = described_class.render(card, viewer: agent)[:text]

    expect(text).to include("карточка ##{card.id}", "лид ##{lead.id}", 'Имя клиента: Анна &lt;b&gt;',
                            'Телефон: +7 910 123-45-67', 'Что нужно клиенту: Продажа / покупка',
                            '✅ пройдена', 'Ответственный: @irina')
    expect(text).not_to include('ID объекта в CRM')
  end

  it 'замечания проверки перечислены с названиями полей' do
    card.update!(check_errors: [{ 'field' => 'comment', 'message' => 'Слишком коротко' },
                                { 'field' => 'lead', 'message' => 'Лид закрыт' }])

    expect(described_class.render(card, viewer: agent)[:text])
      .to include('❌ 2 замеч.', '• Итог разговора с клиентом: Слишком коротко', '• Лид: Лид закрыт')
  end

  it 'черновик с пройденной проверкой: автору — править и отправить' do
    expect(callbacks(described_class.render(card, viewer: agent)))
      .to eq(["wiz:s:crm_edit:#{card.id}", "crm_card:#{card.id}:submit"])
  end

  it 'непройденная проверка — кнопки «На модерацию» нет' do
    card.update!(check_errors: [{ 'field' => 'phone', 'message' => 'не заполнено' }])

    expect(callbacks(described_class.render(card, viewer: agent))).to eq(["wiz:s:crm_edit:#{card.id}"])
  end

  it 'на модерации: модератору — править, вернуть, одобрить; автору — ничего' do
    card.update!(status: 'pending_review')

    expect(callbacks(described_class.render(card, viewer: director))).to eq(
      ["wiz:s:crm_edit:#{card.id}", "wiz:s:crm_rework:#{card.id}", "wiz:s:crm_approve:#{card.id}"]
    )
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'возврат на доработку показывает, кто и что просил' do
    card.update!(status: 'needs_rework', reviewer: director)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: director,
                             comment: 'Уточни бюджет')

    expect(described_class.render(card, viewer: agent)[:text])
      .to include('Вернули на доработку', '@oksana', 'Уточни бюджет')
  end

  it 'сбой выгрузки: текст ошибки и совет проверить CRM; повтор — только модератору' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    expect(described_class.render(card, viewer: director)[:text]).to include('HTTP 502', 'найди клиента в CRM по телефону')
    expect(callbacks(described_class.render(card, viewer: director))).to eq(["crm_card:#{card.id}:retry"])
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'сбой выгрузки, но заявка уже есть в CRM (crm_id проставлен) — кнопки повтора нет, ' \
     'Workflow.retry_export! всё равно бы отказал' do
    card.update!(status: 'export_failed', crm_id: '4242',
                 export_error: 'Заявка уже создана в CRM под номером 4242, но статус не записан. ' \
                                'Не повторяй выгрузку — поправь статус вручную.')

    expect(callbacks(described_class.render(card, viewer: director))).to eq([])
  end

  it 'зависшая выгрузка: предупреждение и повтор модератору' do
    card.update!(status: 'exporting')
    card.update_columns(updated_at: 20.minutes.ago)

    expect(described_class.render(card, viewer: director)[:text]).to include('висит дольше 15 минут')
    expect(callbacks(described_class.render(card, viewer: director))).to eq(["crm_card:#{card.id}:retry"])
  end

  it 'одобренная заявка, не ушедшая в выгрузку за 15 минут, — повтор модератору' do
    card.update!(status: 'approved')
    card.update_columns(updated_at: 20.minutes.ago)

    expect(callbacks(described_class.render(card, viewer: director))).to eq(["crm_card:#{card.id}:retry"])
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'лид переназначили — кнопки правки у нового ответственного, у прежнего автора — нет' do
    petr = crm_staff(tg_user_id: 98_504, username: 'petr')
    lead.update!(assigned_to: petr)

    expect(callbacks(described_class.render(card, viewer: petr))).to include("wiz:s:crm_edit:#{card.id}")
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'лид с пометкой «возможно, сотрудник» — предупреждение модератору, но не запрет' do
    lead.update!(staff_test: true, staff_test_matched_by: 'name_staff_first')

    view = described_class.render(card, viewer: agent)

    expect(view[:text]).to include('возможная заявка сотрудника', 'name_staff_first')
    expect(callbacks(view)).to include("crm_card:#{card.id}:submit")
  end

  it 'сотрудник без прав видит карточку без кнопок' do
    auditor = crm_staff(tg_user_id: 98_503, position: '40')

    expect(described_class.render(card, viewer: auditor)[:keyboard]).to eq([])
  end
end
