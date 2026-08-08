# frozen_string_literal: true

require 'rails_helper'

# Регресс на prod-инцидент «каталог victory62 → 0».
# archive_missing ретайрит каждый активный Property, чей id отсутствует в seen_ids —
# безопасно ТОЛЬКО при полном sweep. Если хоть один сегмент get-ids провалился, seen_ids
# неполон, и архивация ложно снимет живые объявления. PR #6 закрыл raise-путь; здесь
# проверяем, что теперь и не-массивный 200 (через raise из Client#get_ids) идёт тем же
# guard'ом — и что легитимно пустой sweep по-прежнему архивирует корректно.
RSpec.describe Topnlab::Importer do
  subject(:importer) { described_class.new(client: client) }

  let(:client) { instance_double(Topnlab::Client) }

  # Активный topnlab-объект в каталоге. validate:false — как в самом импортёре
  # (CRM-payload'ы не всегда проходят строгие validates); geocode/after_validation
  # при этом не срабатывает.
  def active_topnlab_property(external_id)
    user = create(:user)
    property = Property.new(
      title:           "Тест объект #{external_id}",
      price:           5_000_000,
      address:         'г. Рязань, ул. Тестовая, 1',
      user:            user,
      external_source: 'topnlab',
      external_id:     external_id.to_s,
      status:          :active
    )
    property.save!(validate: false)
    property
  end

  context 'когда get-ids проваливается на всех сегментах (raise)' do
    before do
      allow(client).to receive(:get_ids).and_raise(Topnlab::Client::Error, 'get-ids вернул не-массив')
    end

    it 'копит fetch_errors, НЕ архивирует и оставляет каталог живым' do
      property = active_topnlab_property(555)

      result = importer.call_inner

      expect(result[:fetch_errors]).to be_positive
      expect(result[:archived]).to eq(0)
      expect(property.reload.status).to eq('active')
    end

    it 'не обращается к get_entities при провале fetch' do
      allow(client).to receive(:get_entities)
      active_topnlab_property(556)

      importer.call_inner

      expect(client).not_to have_received(:get_entities)
    end
  end

  context 'когда sweep успешен, но легитимно пуст ([] на всех сегментах)' do
    before { allow(client).to receive(:get_ids).and_return([]) }

    it 'archive_missing срабатывает и архивирует отсутствующий объект' do
      property = active_topnlab_property(777)

      result = importer.call_inner

      expect(result[:fetch_errors]).to eq(0)
      expect(result[:archived]).to be_positive
      expect(property.reload.status).to eq('archived')
    end
  end
end
