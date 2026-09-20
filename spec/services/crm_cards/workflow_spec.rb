# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Workflow do
  let(:notifier) do
    instance_double(CrmCards::Notifier, submitted: nil, returned: nil, approved: nil, released: nil, exported: nil, export_failed: nil)
  end
  let(:exporter) { instance_double(CrmCards::LeadExporter) }
  let(:workflow) { described_class.new(notifier: notifier, exporter: exporter) }

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_701, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_702, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:values) do
    { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
      'comment' => 'Ищет двушку в Канищево до 6 млн, ипотека одобрена' }
  end

  def filled_card
    workflow.upsert_lead_card!(lead: lead, actor: agent, values: values).card
  end

  describe '#upsert_lead_card!' do
    it 'создаёт черновик с автором и итогом проверки' do
      result = workflow.upsert_lead_card!(lead: lead, actor: agent, values: values)

      expect(result).to be_ok
      expect(result.card).to have_attributes(status: 'draft', author_id: agent.id)
      expect(result.card.check_passed?).to be(true)
    end

    it 'дописывает поля в тот же черновик и не плодит вторую карточку' do
      workflow.upsert_lead_card!(lead: lead, actor: agent, values: values.except('comment'))

      expect { workflow.upsert_lead_card!(lead: lead, actor: agent, values: { 'comment' => values['comment'] }) }
        .not_to change(CrmCard, :count)
      expect(CrmCard.last.payload).to include('name' => 'Анна', 'comment' => values['comment'])
    end

    it 'должность без права create_lead — отказ, карточки нет' do
      auditor = crm_staff(tg_user_id: 98_703, position: '40')

      result = workflow.upsert_lead_card!(lead: lead, actor: auditor, values: values)

      expect(result.error).to include('не выданы права')
      expect(CrmCard.count).to eq(0)
    end

    it 'новый ответственный по лиду перенимает черновик' do
      filled_card
      petr = crm_staff(tg_user_id: 98_704, username: 'petr')
      lead.update!(assigned_to: petr)

      result = workflow.upsert_lead_card!(lead: lead, actor: petr, values: {})

      expect(result).to be_ok
      expect(result.card.author).to eq(petr)
    end

    it 'посторонний сотрудник чужой черновик не правит' do
      card = filled_card
      petr = crm_staff(tg_user_id: 98_705, username: 'petr')

      expect(workflow.update_fields!(card, { 'name' => 'Пётр' }, actor: petr).error).to include('ведёт @irina')
    end

    it 'автор, у которого забрали лид, карточку больше не отправляет — отправляет новый ответственный' do
      card = filled_card
      petr = crm_staff(tg_user_id: 98_706, username: 'petr')
      lead.update!(assigned_to: petr)

      expect(workflow.submit!(card, actor: agent).error).to include('ведёт @petr')
      expect(workflow.submit!(card.reload, actor: petr)).to be_ok
      expect(card.reload.author).to eq(petr)
    end
  end

  describe '#submit!' do
    it 'проверенную карточку отправляет на модерацию и зовёт модераторов' do
      card = filled_card

      expect(workflow.submit!(card, actor: agent)).to be_ok
      expect(card.reload).to be_status_pending_review
      expect(card.submitted_at).to be_present
      expect(card.transitions.last).to have_attributes(from_status: 'draft', to_status: 'pending_review', actor_id: agent.id)
      expect(notifier).to have_received(:submitted).with(card, moderators: [director])
    end

    it 'непройденная проверка — остаётся черновиком' do
      card = workflow.upsert_lead_card!(lead: lead, actor: agent, values: values.merge('comment' => 'коротко')).card

      expect(workflow.submit!(card, actor: agent).error).to include('Машинная проверка не пройдена')
      expect(card.reload).to be_status_draft
      expect(notifier).not_to have_received(:submitted)
    end

    it 'модераторов нет — не отправляет в пустоту' do
      director.update!(status: 'inactive')

      expect(workflow.submit!(filled_card, actor: agent).error).to include('Модераторов')
    end
  end

  describe 'решения модератора' do
    let(:card) { filled_card.tap { |c| workflow.submit!(c, actor: agent) }.reload }

    it 'агент одобрить не может' do
      expect(workflow.approve!(card, actor: agent).error).to include('только модератор')
    end

    it 'возврат на доработку требует комментарий и пишет его в журнал' do
      expect(workflow.return_for_rework!(card, actor: director, comment: ' ').error).to include('комментарий')

      expect(workflow.return_for_rework!(card, actor: director, comment: 'Уточни бюджет')).to be_ok
      expect(card.reload).to be_status_needs_rework
      expect(card.last_rework_comment).to eq('Уточни бюджет')
      expect(notifier).to have_received(:returned).with(card, comment: 'Уточни бюджет')
    end

    it 'после доработки карточку снова можно отправить' do
      workflow.return_for_rework!(card, actor: director, comment: 'Уточни бюджет')
      workflow.update_fields!(card.reload, { 'comment' => 'Бюджет 6 млн, ипотека одобрена в Сбере' }, actor: agent)

      expect(workflow.submit!(card.reload, actor: agent)).to be_ok
    end

    it 'на модерации поле правит модератор, автор — нет' do
      expect(workflow.update_fields!(card, { 'name' => 'Анна Смирнова' }, actor: agent).error).to include('на модерации')
      expect(workflow.update_fields!(card, { 'name' => 'Анна Смирнова' }, actor: director)).to be_ok
    end

    it 'одобрение заявки выгрузку НЕ запускает — её разрешает руководитель' do
      expect { workflow.approve!(card, actor: director) }.not_to have_enqueued_job(CrmCards::ExportJob)
      expect(card.reload).to have_attributes(status: 'approved', reviewer_id: director.id, export_mode: 'api',
                                             released_at: nil)
      expect(notifier).to have_received(:approved).with(card, exporters: [director])
    end

    it 'разрешение руководителя ставит выгрузку в очередь и записывает, кто решил' do
      workflow.approve!(card, actor: director)

      expect { workflow.release_for_export!(card.reload, actor: director) }
        .to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to have_attributes(released_by_id: director.id)
      expect(card.released_at).to be_present
      expect(notifier).to have_received(:released).with(card)
    end

    it 'без права выгрузки разрешить нельзя' do
      workflow.approve!(card, actor: director)

      expect(workflow.release_for_export!(card.reload, actor: agent).error).to include('руководитель')
      expect(card.reload.released_at).to be_nil
    end

    it 'повторное разрешение не заводит вторую выгрузку' do
      workflow.approve!(card, actor: director)
      workflow.release_for_export!(card.reload, actor: director)

      expect { workflow.release_for_export!(card.reload, actor: director) }
        .not_to have_enqueued_job(CrmCards::ExportJob)
    end

    it 'клиента завели в CRM, пока карточка ждала решения, — выгрузить нельзя' do
      workflow.approve!(card, actor: director)
      # Между одобрением и решением руководителя проходят часы и дни: за это
      # время клиента могли внести в CRM руками. Вторая заявка — дубль.
      lead.lead_ref.update!(crm_id: '4455')

      result = workflow.release_for_export!(card.reload, actor: director)

      expect(result.error).to include('больше не проходит')
      expect(card.reload.released_at).to be_nil
    end

    it 'одобренная, но не разрешённая карточка застрявшей не считается' do
      workflow.approve!(card, actor: director)
      card.reload.update_columns(updated_at: 20.minutes.ago)

      expect(card.reload).not_to be_export_stale
    end

    it 'одобренная, но не разрешённая заявка не выгружается' do
      workflow.approve!(card, actor: director)

      expect(workflow.export!(card.reload).error).to include('не разрешена')
      expect(card.reload).to be_status_approved
    end

    it 'лид закрылся, пока карточка ждала, — одобрить нельзя' do
      card # создана и отправлена на модерацию, пока лид ещё открыт — закрываем лид уже после
      lead.update!(current_stage: 'closed_lost')

      expect(workflow.approve!(card, actor: director).error).to include('больше не проходит')
      expect(card.reload).to be_status_pending_review
    end
  end

  describe '#export!' do
    let(:card) do
      filled_card.tap { |c| workflow.submit!(c, actor: agent) }.reload
                 .tap { |c| workflow.approve!(c, actor: director) }.reload
                 .tap { |c| workflow.release_for_export!(c, actor: director) }.reload
    end
    let(:outcome) { CrmCards::LeadExporter::Outcome.new(crm_id: '4455', warning: nil) }

    it 'успешная выгрузка: номер в карточке и у заявки с сайта, журнал' do
      allow(exporter).to receive(:call).and_return(outcome)

      expect(workflow.export!(card)).to be_ok
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '4455')
      expect(card.transitions.map(&:to_status)).to end_with('exporting', 'exported')
      expect(lead.lead_ref.reload.crm_id).to eq('4455')
      expect(notifier).to have_received(:exported).with(card, warning: nil)
    end

    it 'второй запуск не выгружает повторно' do
      allow(exporter).to receive(:call).and_return(outcome)

      workflow.export!(card)

      expect(workflow.export!(card.reload)).not_to be_ok
      expect(exporter).to have_received(:call).once
    end

    it 'CRM приняла заявку, но статус записать не удалось — номер не теряется, повтор запрещён' do
      allow(exporter).to receive(:call).and_return(outcome)
      allow(workflow).to receive(:record_export!).and_return(CrmCards::Workflow::Result.new(ok: false, error: 'boom'))

      workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', crm_id: '4455')
      expect(card.export_error).to include('4455').and include('Не повторяй')
      retry_result = nil
      expect { retry_result = workflow.retry_export!(card, actor: director) }.not_to have_enqueued_job(CrmCards::ExportJob)
      expect(retry_result.error).to include('уже есть в CRM')
    end

    it 'CRM приняла заявку, но запись статуса упала — export! не падает, номер сохранён' do
      allow(exporter).to receive(:call).and_return(outcome)
      allow(workflow).to receive(:record_export!).and_raise(ActiveRecord::StatementInvalid, 'db down')

      expect { workflow.export!(card) }.not_to raise_error

      expect(card.reload).to have_attributes(status: 'export_failed', crm_id: '4455')
    end

    it 'CRM приняла заявку, но номер не записался в базу — номер остаётся в логе' do
      allow(exporter).to receive(:call).and_return(outcome)
      allow(card).to receive(:update_columns).and_raise(ActiveRecord::ConnectionNotEstablished, 'db gone')
      allow(Rails.logger).to receive(:error)

      expect { workflow.export!(card) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(Rails.logger).to have_received(:error).with(a_string_including('номером 4455', "##{card.id}"))
    end

    it 'ошибка CRM — export_failed с текстом; повтор только модератором' do
      allow(exporter).to receive(:call).and_raise(Topnlab::Client::Error, 'POST /call/main/importClient/: HTTP 502')

      workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_error: a_string_including('HTTP 502'))
      expect(notifier).to have_received(:export_failed).with(card)
      expect(workflow.retry_export!(card, actor: agent).error).to include('только модератор')
      expect { workflow.retry_export!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to be_status_approved
    end

    it 'одобренная заявка без выгрузки дольше 15 минут — модератор запускает её снова' do
      card.update_columns(updated_at: 20.minutes.ago)

      expect { workflow.retry_export!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    end
  end
end
