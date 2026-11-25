# frozen_string_literal: true

require 'rails_helper'

# AdminMailer.property_reported — success-path POST /properties/:id/report
# (#262): нит-пик из ревью — request-спек проверял только enqueue, а рендер
# шаблона и получателя не проверял никто. Здесь mailer выполняется по-настоящему.
RSpec.describe AdminMailer do
  let(:property) { create(:property) }

  describe '#property_reported' do
    let(:mail) do
      described_class.property_reported(property, nil, 'fraud', 'Подозрительное объявление <script>alert(1)</script>')
    end

    it 'шлёт на адрес администратора из ENV (с дефолтом)' do
      expect(mail.to).to eq([ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru')])
    end

    it 'включает объект и причину в subject' do
      expect(mail.subject).to include(property.title)
      expect(mail.subject).to include('fraud')
    end

    it 'рендерит ссылку на объект и анонимного отправителя' do
      expect(mail.body.decoded).to include(property_url(property))
      expect(mail.body.decoded).to include('анонимный посетитель')
    end

    it 'санитизирует HTML в пользовательском description (simple_format)' do
      mail = described_class.property_reported(property, nil, 'fraud',
                                               'цена < 5 млн <script>alert(1)</script>')
      body = mail.body.decoded
      # Сырой текст экранируется, script-тег вырезается санитайзером —
      # исполнение JS в почтовом клиенте админа невозможно.
      expect(body).to include('цена &lt; 5 млн')
      expect(body).not_to include('<script')
    end
  end
end
