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

  # ВНИМАНИЕ: раньше здесь утверждалось обратное — что пустой sweep архивирует.
  # Это и была механика обоих инцидентов: «ничего не увидели» = «архивируй всё».
  # У агентства не бывает нуля активных объектов, поэтому пустой seen_ids
  # трактуется как сбой, а не как сигнал к массовой архивации.
  context 'когда sweep успешен, но seen_ids пуст ([] на всех сегментах)' do
    before { allow(client).to receive(:get_ids).and_return([]) }

    it 'НЕ архивирует ничего — пустой seen_ids трактуется как сбой' do
      property = active_topnlab_property(777)

      result = importer.call_inner

      expect(result[:fetch_errors]).to eq(0)
      expect(result[:archived]).to eq(0)
      expect(property.reload.status).to eq('active')
    end
  end

  # Доминирующий путь, который PR #6 и первая версия PR #10 не закрывали:
  # seen_ids набирается из payload'ов get_entities, а не из get-ids. Битый
  # get-entities при валидном get-ids давал fetch_errors == 0 → guard молчал.
  context 'когда get-ids валиден, но get-entities возвращает не-Hash' do
    before do
      allow(client).to receive(:get_ids).and_return([777])
      allow(client).to receive(:get_entities)
        .and_raise(Topnlab::Client::Error, 'get-entities вернул не-Hash')
    end

    it 'копит fetch_errors и оставляет каталог живым' do
      property = active_topnlab_property(777)

      result = importer.call_inner

      expect(result[:fetch_errors]).to be_positive
      expect(result[:archived]).to eq(0)
      expect(property.reload.status).to eq('active')
    end
  end

  # Частичный сбой опаснее полного: он тише. Один битый сегмент из двенадцати
  # раньше уносил в архив всё, чего не оказалось в неполном seen_ids.
  context 'когда часть сегментов отдала объекты, а один провалился' do
    before do
      call = 0
      allow(client).to receive(:get_ids) do
        call += 1
        raise Topnlab::Client::Error, 'сегмент упал' if call == 2

        call == 1 ? [777] : []
      end
      allow(client).to receive(:get_entities).and_return(
        { '777' => { 'id' => 777, 'deal_state' => 'active' } }
      )
    end

    it 'не архивирует объект, отсутствующий в неполном seen_ids' do
      other = active_topnlab_property(888)

      result = importer.call_inner

      expect(result[:fetch_errors]).to be_positive
      expect(result[:archived]).to eq(0)
      expect(other.reload.status).to eq('active')
    end
  end
end
