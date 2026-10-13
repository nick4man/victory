# frozen_string_literal: true

require 'rails_helper'

# `/lead` — ручной вход в конвейер: руководитель диктует телефон и имя прямо в
# чате, дальше Inquiry через after_create_commit запускает Lead::Intake и
# карточка появляется в #ДИСПЕТЧЕРСКОЙ.
#
# Вся команда держится на одном разборе LEAD_REGEX, и спеки у неё не было.
# Регулярка с тремя опциональными группами — ровно то место, где поведение
# расходится с ожиданием тихо: лид создастся, просто с мусором в имени.
#
# Lead::Intake здесь застаблен: конвейер публикации — своя зона
# ответственности, а нам важно, что именно легло в Inquiry.
RSpec.describe Telegram::WorkBot::Commands::Lead do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **_opts|
      sent << text
      { 'message_id' => 1 }
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 98_101, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 98_101)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 98_102, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 98_102)
  end

  before { allow(Lead::Intake).to receive(:call).and_return(nil) }

  def run(args, user: manager)
    msg = { 'message_id' => 41, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
            'message_thread_id' => 1, 'text' => "/lead #{args}" }
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  def created
    Inquiry.order(:id).last
  end

  describe 'happy path' do
    it 'создаёт заявку с телефоном, именем и свободным текстом' do
      expect { run('+79001234567 Анна, бюджет 6 млн, ЖК Северный') }
        .to change(Inquiry, :count).by(1)

      expect(created.name).to eq('Анна')
      expect(created.message).to eq('бюджет 6 млн, ЖК Северный')
    end

    it 'нормализует телефон до цифр — в БД попадают только они' do
      run('8 (900) 123-45-67 Пётр')
      expect(created.phone).to eq('89001234567')
      expect(created.name).to eq('Пётр')
    end

    it 'помечает источник tg_manual — так ручные лиды отделяются от сайтовых' do
      run('+79001234567 Анна')
      expect(created.source).to eq('tg_manual')
      expect(created.inquiry_type).to eq('quick_inquiry')
    end

    it 'без имени подставляет заглушку, а не падает на валидации' do
      run('+79001234567')
      expect(created.name).to eq('Клиент из TG')
      expect(created.message).to be_nil
    end

    it 'отвечает номером заявки — по нему лид ищут дальше' do
      run('+79001234567 Анна')
      expect(sent.join).to include("##{created.id}")
    end

    it 'запускает конвейер публикации карточки' do
      run('+79001234567 Анна')
      expect(Lead::Intake).to have_received(:call)
    end
  end

  describe 'права' do
    it 'агенту команда недоступна — иначе спам в чате становится лидами' do
      expect { run('+79001234567 Анна', user: agent) }.not_to change(Inquiry, :count)
      expect(sent.join).to include('руководителям')
    end
  end

  describe 'разбор формата' do
    it 'без телефона отвечает подсказкой и ничего не создаёт' do
      expect { run('Анна, хочет двушку') }.not_to change(Inquiry, :count)
      expect(sent.join).to include('Не понимаю формат')
    end

    it 'слишком короткий номер за телефон не считает' do
      expect { run('12345 Анна') }.not_to change(Inquiry, :count)
    end

    it 'пустой ввод — подсказка с примером' do
      expect { run('') }.not_to change(Inquiry, :count)
      expect(sent.join).to include('/lead +79001234567')
    end

    it 'телефон обязан идти первым — имя впереди номера не распознаётся' do
      expect { run('Анна +79001234567') }.not_to change(Inquiry, :count)
    end

    # ⚠️ Фиксация текущего поведения, а не одобрение его.
    #
    # Группа имени — `\p{L}[\p{L}\s-]{1,40}` — жадная и не знает, где имя
    # кончается. Разделитель между именем и комментарием опционален, поэтому
    # без запятой имя утягивает соседние слова: «Анна бюджет». Лид при этом
    # создаётся молча, и в CRM уезжает кривое имя клиента.
    #
    # Пример намеренно зелёный: он документирует ловушку и покраснеет, если
    # разбор решат ужесточить — тогда это будет осознанная правка, а не сюрприз.
    it 'без запятой имя захватывает следующее слово' do
      run('+79001234567 Анна бюджет 6 млн')
      expect(created.name).to eq('Анна бюджет')
      expect(created.message).to eq('6 млн')
    end
  end

  describe 'отказ базы' do
    it 'показывает причину отказа валидации, а не общий «⚠️ Ошибка»' do
      invalid = Inquiry.new
      invalid.errors.add(:phone, 'в чёрном списке')
      allow(::Inquiry).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(invalid))

      run('+79001234567 Анна')
      expect(sent.join).to include('в чёрном списке')
      expect(sent.join).not_to include('undefined method')
    end
  end
end
