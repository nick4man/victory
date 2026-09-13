# frozen_string_literal: true

require 'rails_helper'

# `/doc` — самая насыщенная команда бота: у неё собственный мини-язык
# (`passport+ snils? egrn+verified poa@reject:причина`), три ветки (init /
# статус / применение) и авторизация по лиду, а не по роли. Спеки не было ни
# у команды, ни у её ветки init.
#
# Здесь проверяется контракт именно команды. Tokenizer и Manager — соседние
# сервисы со своей зоной ответственности, но разрывать их на моки в тех
# примерах, где важен результат, смысла нет: дешевле прогнать настоящие
# DocumentRequirement и посмотреть на состояние.
RSpec.describe Telegram::WorkBot::Commands::Doc do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **_opts|
      sent << text
      { 'message_id' => 1 }
    end
    client
  end

  let!(:assignee) do
    TelegramUser.create!(tg_user_id: 98_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 98_001)
  end
  let!(:stranger) do
    TelegramUser.create!(tg_user_id: 98_002, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 98_002)
  end
  # Директор без legacy-флага is_manager: Commands::Base после Iter 41 обязан
  # его пускать через manager_or_director?. Это ровно тот случай, из-за которого
  # фикс и делали, так что он заслуживает примера.
  let!(:director) do
    TelegramUser.create!(tg_user_id: 98_003, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: false, status: 'active', dm_chat_id: 98_003)
  end

  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 1200, assigned_to: assignee)
  end

  def run(args, user: assignee, reply_to: 1200)
    msg = { 'message_id' => 31, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
            'message_thread_id' => 17,
            'text' => "/doc #{args}" }
    msg['reply_to_message'] = { 'message_id' => reply_to } if reply_to
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  def dr(kind)
    DocumentRequirement.find_by(lead_event_id: lead.id, kind: kind)
  end

  describe 'привязка к лиду' do
    it 'без reply на якорь объясняет, что нужен reply' do
      run('passport+', reply_to: nil)
      expect(sent.join).to include('reply на якорную карточку')
      expect(DocumentRequirement.count).to eq(0)
    end

    it 'reply на чужое сообщение лида не находит — тоже отказ' do
      run('passport+', reply_to: 999_999)
      expect(sent.join).to include('reply на якорную карточку')
    end
  end

  describe 'авторизация' do
    it 'ответственный по лиду управляет документами' do
      run('passport+')
      expect(dr('passport_main')).to be_status_received
    end

    it 'директор без is_manager тоже может — иначе он заперт снаружи своего же АН' do
      run('passport+', user: director)
      expect(dr('passport_main')).to be_status_received
    end

    it 'посторонний агент получает отказ с именем ответственного' do
      run('passport+', user: stranger)
      expect(DocumentRequirement.count).to eq(0)
      expect(sent.join).to include('🚫').and include('@irina')
    end
  end

  describe '/doc init' do
    it 'разворачивает чек-лист по шаблону и называет шаблон в ответе' do
      expect { run('init') }.to change(DocumentRequirement, :count).by(3)
      expect(dr('passport_main')).to be_present
      expect(dr('egrn_excerpt')).to be_present
      expect(dr('contract_sale')).to be_present
      expect(sent.join).to include('default_sale')
    end

    it 'создаёт документы в состоянии «не запрошены» — запрос делает человек' do
      run('init')
      expect(DocumentRequirement.pluck(:status).uniq).to eq(['not_requested'])
    end

    it 'повторный init не плодит дубли и честно говорит, сколько пропустил' do
      run('init')
      sent.clear

      expect { run('init') }.not_to change(DocumentRequirement, :count)
      expect(sent.join).to include('Пропущено')
    end

    it 'отказ билдера показывает причину, а не молчит' do
      failure = DocumentChecklist::Builder::Result.new(
        success: false, created: [], skipped: [], template_key: nil, error: 'шаблон не найден'
      )
      allow_any_instance_of(DocumentChecklist::Builder).to receive(:call).and_return(failure)

      run('init')
      expect(sent.join).to include('шаблон не найден')
    end
  end

  describe '/doc без аргументов — статус' do
    it 'на пустом чек-листе подсказывает init' do
      run('')
      expect(sent.join).to include('/doc init')
    end

    it 'показывает прогресс и раскладывает документы по группам' do
      run('init')
      run('passport+verified')
      run('snils?')
      sent.clear

      run('')
      status = sent.join
      expect(status).to include("Документы по лиду ##{lead.id}")
      expect(status).to include('✅ ГОТОВЫ').and include('⏳ ЗАПРОШЕНЫ')
      # 1 verified из 4 записей (3 из init + snils) → 25%
      expect(status).to include('1/4').and include('25%')
    end
  end

  describe 'мини-язык' do
    it 'batch: помечает полученным и запрашивает — за один вызов' do
      run('passport+ snils?')
      expect(dr('passport_main')).to be_status_received
      expect(dr('snils')).to be_status_requested
      expect(dr('snils').requested_at).to be_present
      expect(sent.join).to include('2 документ(ов)')
    end

    it 'комбо-суффикс +verified — атомарный прыжок через received' do
      run('egrn+verified')
      expect(dr('egrn_excerpt')).to be_status_verified
      expect(dr('egrn_excerpt').verified_by_id).to eq(assignee.id)
    end

    it '@reject:причина сохраняет причину и автора отказа' do
      run('poa@reject:no_notary')
      rec = dr('power_of_attorney')
      expect(rec).to be_status_rejected
      expect(rec.metadata['rejection_reason']).to eq('no_notary')
      expect(rec.metadata['rejected_by']).to eq('@irina')
    end

    it 'понимает русские алиасы наравне с латинскими' do
      run('ипотека?')
      expect(dr('mortgage_approval')).to be_status_requested
    end

    it 'минус откатывает документ в «не запрошен»' do
      run('passport?')
      run('passport-')
      expect(dr('passport_main')).to be_status_not_requested
      expect(dr('passport_main').requested_at).to be_nil
    end

    it 'повторное «получен» идемпотентно — received_at не переписывается' do
      run('passport+')
      first_received_at = dr('passport_main').received_at

      run('passport+')
      expect(dr('passport_main').received_at).to eq(first_received_at)
    end
  end

  describe 'мусорный ввод' do
    it 'полностью неразобранный ввод ничего не меняет' do
      expect { run('чепуха') }.not_to change(DocumentRequirement, :count)
      expect(sent.join).to include('не понимаю')
    end

    it 'неизвестный тип документа назван в ответе' do
      run('квадрокоптер+')
      expect(sent.join).to include('не знаю тип документа')
    end

    # Смешанный ввод — самый коварный случай: часть применилась, часть нет.
    # Молча проглотить хвост нельзя, иначе агент уверен, что отметил всё.
    it 'применяет понятое и предупреждает о непонятом' do
      run('passport+ абракадабра')
      expect(dr('passport_main')).to be_status_received
      expect(sent.join).to include('Обновлено: 1').and include('не понимаю')
    end

    it 'экранирует мусор — parse_mode=HTML не должен ронять ответ' do
      run('<b>+')
      expect(sent.join).to include('&lt;b')
      expect(sent.join).not_to include('<b>+')
    end
  end
end
