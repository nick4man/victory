# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Workflow do
  let(:notifier) do
    instance_double(CrmCards::Notifier, submitted: nil, returned: nil, approved: nil, exported: nil, export_failed: nil)
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

    # Регресс ревью #94: new_record? в can_edit? пропускал любого с create_lead —
    # карточку можно было завести по лиду, назначенному другому сотруднику.
    it 'чужой назначенный лид — отказ, карточка не создана' do
      petr = crm_staff(tg_user_id: 98_705, username: 'petr')

      result = workflow.upsert_lead_card!(lead: lead, actor: petr, values: values)

      expect(result.error).to include('ведёт @irina')
      expect(CrmCard.count).to eq(0)
    end

    it 'модератор может завести карточку по назначенному лиду' do
      expect(workflow.upsert_lead_card!(lead: lead, actor: director, values: values)).to be_ok
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

    it 'одобрение заявки ставит выгрузку в очередь' do
      expect { workflow.approve!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to have_attributes(status: 'approved', reviewer_id: director.id, export_mode: 'api')
      expect(notifier).to have_received(:approved).with(card)
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

      expect(card.reload).to have_attributes(status: 'export_failed', crm_id: '4455', export_retryable: false)
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
      allow(Rails.logger).to receive(:error)
      # Запись номера — атомарный update_all на relation с токеном; роняем
      # именно его, claim (другие where) остаётся рабочим.
      raising = Module.new do
        def update_all(*_args, **_kwargs)
          raise ActiveRecord::ConnectionNotEstablished, 'db gone'
        end
      end
      allow(CrmCard).to receive(:where).and_wrap_original do |m, *args, **kwargs|
        relation = m.call(*args, **kwargs)
        relation.extend(raising) if kwargs.key?(:export_attempt_token)
        relation
      end

      expect { workflow.export!(card) }.to raise_error(ActiveRecord::ConnectionNotEstablished)
      expect(Rails.logger).to have_received(:error).with(a_string_including('номером 4455', "##{card.id}"))
    end

    it 'детерминированный отказ CRM (403) — export_failed с текстом; повторяемый сбой, повтор только модератором' do
      allow(exporter).to receive(:call).and_raise(Topnlab::Client::Error, 'POST /call/main/importClient/: 403 Forbidden — API key rejected')

      workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_error: a_string_including('403'),
                                             export_retryable: true)
      expect(notifier).to have_received(:export_failed).with(card)
      expect(workflow.retry_export!(card, actor: agent).error).to include('только модератор')
      expect { workflow.retry_export!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to be_status_approved
    end

    # Сквозные регрессы ревью PR #210 (round 7): 5xx и битое тело 200 —
    # ответ мог прийти от шлюза уже ПОСЛЕ того, как backend принял запрос.
    # Не доказательство «заявка не создана»: export_retryable false, retry
    # без привязки номера не ставит job.
    it 'HTTP 502 от шлюза — неоднозначный исход: retryable false, повтор запрещён' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
        .to_return(status: 502, body: 'Bad Gateway')
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: false)
      retry_result = nil
      expect do
        retry_result = real_workflow.retry_export!(card, actor: director)
      end.not_to have_enqueued_job(CrmCards::ExportJob)
      expect(retry_result.error).to include('Повтор запрещён')
    end

    it 'malformed JSON в ответе 200 — неоднозначный исход: retryable false, повтор запрещён' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
        .to_return(status: 200, body: '<html>cut off')
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: false)
      expect(real_workflow.retry_export!(card, actor: director).error).to include('Повтор запрещён')
    end

    # Регресс ревью PR #210 (round 6/7): неоднозначный транспортный исход —
    # CRM могла принять заявку, а ответ потеряться. Новый importClient
    # запрещён безусловно (сверка глазами не закрывает окно между проверкой
    # и повтором): восстановление — attach_export_number! — модератор
    # находит заявку в CRM по телефону и привязывает номер.
    it 'потерянный ответ CRM — неоднозначный сбой: повтор запрещён, привязка номера' do
      allow(exporter).to receive(:call).and_raise(Topnlab::Client::AmbiguousError, 'ReadTimeout после отправки')

      workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: false)
      expect(workflow.retry_export!(card, actor: director).error).to include('Повтор запрещён')

      expect(workflow.attach_export_number!(card, crm_id: '7788', actor: director)).to be_ok
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '7788')
      expect(exporter).to have_received(:call).once
      expect(notifier).to have_received(:exported).with(card)
    end

    # Сквозной регресс ревью PR #210 (round 6): настоящий Topnlab::Client с
    # WebMock оборачивает транспортный ReadTimeout в AmbiguousError — double
    # с сырым Net::ReadTimeout этот путь не покрывает.
    it 'реальный клиент: ReadTimeout → export_retryable false, автоповтор не ставит job' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/}).to_raise(Net::ReadTimeout)
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: false)
      retry_result = nil
      expect do
        retry_result = real_workflow.retry_export!(card, actor: director)
      end.not_to have_enqueued_job(CrmCards::ExportJob)
      expect(retry_result.error).to include('Повтор запрещён')
    end

    it 'одобренная заявка без выгрузки дольше 15 минут — модератор запускает её снова' do
      card.update_columns(updated_at: 20.minutes.ago)

      expect { workflow.retry_export!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    end

    # Регресс ревью PR #210: пока попытка жива (свежий 'exporting'), retry
    # отказывает и второй job не стартует — второй неидемпотентный
    # importClient невозможен, гонки двух живых попыток нет.
    it 'живая выгрузка блокирует повтор: retry отказывает, вторая попытка не стартует' do
      retry_result = nil
      second_result = nil
      lock_calls = 0
      allow(CrmCards::ExportLock).to receive(:try_acquire).and_wrap_original do |m, c|
        lock_calls += 1
        lock_calls == 1 ? m.call(c) : false
      end
      allow(exporter).to receive(:call) do |c|
        # Первая попытка «в сети» внутри exporter.call: модератор жмёт
        # «Повторить» и второй job встаёт в очередь (try_acquire занят).
        retry_result = workflow.retry_export!(c.reload, actor: director)
        second_result = workflow.export!(c.reload)
        outcome
      end

      expect(workflow.export!(card)).to be_ok

      expect(retry_result).not_to be_ok
      expect(retry_result.error).to include('повтор запрещён')
      expect(second_result).not_to be_ok
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '4455')
      expect(exporter).to have_received(:call).once
    end

    # Регресс ревью PR #210: retry из 'exporting' не смотрит на advisory
    # lock вовсе — свежий статус уже отвечает «живо». Второй export! не
    # пройдёт атомарный захват статуса, даже когда lock свободен.
    it 'живая попытка: retry отказывает по статусу, второго exporter.call нет' do
      retry_result = nil
      second_result = nil
      allow(exporter).to receive(:call) do |c|
        retry_result = workflow.retry_export!(c.reload, actor: director)
        second_result = workflow.export!(c.reload)
        outcome
      end

      expect(workflow.export!(card)).to be_ok

      expect(retry_result).not_to be_ok
      expect(retry_result.error).to include('повтор запрещён')
      expect(second_result).not_to be_ok
      expect(second_result.error).to include('не ждёт выгрузки')
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '4455')
      expect(exporter).to have_received(:call).once
    end

    # Регресс ревью PR #210 (round 5, сценарий ревьюера): stale 'exporting'
    # при свободном advisory lock — первая попытка всё ещё жива внутри
    # exporter.call (разрыв DB-сессии отпускает lock раньше HTTP-вызова, по
    # lockу живость не доказать). Автоматический retry запрещён: второго
    # exporter.call не существует, пока первая попытка жива.
    it 'stale-выгрузка: автоматический retry отказывает — второго exporter.call нет' do
      retry_result = nil
      allow(exporter).to receive(:call) do |c|
        c.update_columns(updated_at: 20.minutes.ago)
        retry_result = workflow.retry_export!(c.reload, actor: director)
        CrmCards::LeadExporter::Outcome.new(crm_id: '1111', warning: nil)
      end

      expect(workflow.export!(card)).to be_ok

      expect(retry_result).not_to be_ok
      expect(retry_result.error).to include('повтор запрещён')
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '1111')
      expect(exporter).to have_received(:call).once
    end

    # Регресс ревью PR #210 (round 7, блокер 1): stale 'exporting', первая
    # попытка ещё жива. Новый importClient запрещён безусловно — модератор
    # сверил CRM глазами и привязывает найденный номер (attach_export_number!):
    # второй exporter.call не существует. Проснувшаяся первая попытка не
    # перезаписывает привязанный номер: токен сменился, условная запись
    # отсекает её.
    it 'stale-выгрузка, живая попытка: retry запрещён, привязка номера, живая попытка не перезаписывает' do
      first_call = true
      retry_result = nil
      attach_result = nil
      allow(exporter).to receive(:call) do |c|
        next CrmCards::LeadExporter::Outcome.new(crm_id: '2222', warning: nil) unless first_call

        first_call = false
        # Первая попытка «в сети», карточка stale: модератор сверил CRM и
        # привязывает номер, пока первая попытка ещё выполняется.
        c.update_columns(updated_at: 20.minutes.ago)
        retry_result = workflow.retry_export!(c.reload, actor: director)
        attach_result = workflow.attach_export_number!(c.reload, crm_id: '7788', actor: director)
        # Проснулась первая попытка с результатом 1111 — условная по токену
        # запись должна отсечь его (токен сменился при attach).
        CrmCards::LeadExporter::Outcome.new(crm_id: '1111', warning: nil)
      end

      stale_result = workflow.export!(card)

      expect(retry_result).not_to be_ok
      expect(retry_result.error).to include('повтор запрещён')
      expect(attach_result).to be_ok
      expect(stale_result).not_to be_ok
      expect(stale_result.error).to include('устарела')
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '7788')
      expect(exporter).to have_received(:call).once
      expect(notifier).to have_received(:exported).with(card).once
    end

    it 'attach_export_number!: только модератор, только цифры, только заявка' do
      card.update!(status: 'export_failed', export_error: 'boom', export_retryable: false)

      expect(workflow.attach_export_number!(card, crm_id: '7788', actor: agent).error).to include('только модератор')
      expect(workflow.attach_export_number!(card, crm_id: 'abc', actor: director).error).to include('только цифры')
      expect(workflow.attach_export_number!(card, crm_id: '7788', actor: director)).to be_ok
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '7788', export_error: nil)
    end

    # Сквозной регресс ревью PR #210 (round 5/8): реальный Topnlab::Client с
    # WebMock; ответ CRM отражает appkey. Секрет не должен доехать до
    # export_error (БД, журнал переходов, Telegram-модераторы).
    it 'appkey из ошибочного ответа CRM не доезжает до export_error' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
        .to_return(status: 200, body: { status: 'error', message: 'duplicate key=test-key' }.to_json)
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: true)
      expect(card.export_error).to include('[FILTERED]')
      expect(card.export_error).not_to include('test-key')
    end

    # Сквозной регресс ревью PR #210 (round 8, блокер 1): ок-ответ с
    # отражённым ключом в insertedId — раньше значение попадало в сообщение
    # исключения через inspect и уезжало в export_error.
    it 'appkey, отражённый в insertedId ок-ответа, не доезжает до export_error' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
        .to_return(status: 200, body: { status: 'ok', insertedId: 'test-key' }.to_json)
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: false)
      expect(card.export_error).not_to include('test-key')
    end

    # Сквозной регресс ревью PR #210 (round 9, блокер 1): телефон и ФИО
    # клиента внутри сериализованного JSON в message ошибки — конечный
    # card.export_error (БД, журнал переходов, Telegram) их не содержит.
    it 'PII внутри сериализованного JSON в message не доезжает до export_error' do
      real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
      stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
        .to_return(status: 200, body: {
                     status: 'error',
                     message: { phone: '79101234567', fullname: 'Анна', code: 409 }.to_json
                   }.to_json)
      real_workflow = described_class.new(notifier: notifier,
                                          exporter: CrmCards::LeadExporter.new(topnlab: real_client))

      real_workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_retryable: true)
      expect(card.export_error).to include('409')
      expect(card.export_error).not_to include('79101234567', 'Анна')
    end
  end
end
