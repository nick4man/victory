# frozen_string_literal: true

require 'rails_helper'

# A2 Фаза 2 — админка справочника ЖК.
#
# Самое хрупкое здесь — взаимодействие soft-delete с default_scope: таб
# «удалённые» и восстановление работают только если запросы идут через
# unscoped. Плюс привязка объектов, которая намеренно обходит колбэки
# модели (иначе выжгли бы квоту Я.Вебмастера на массовом наполнении).
RSpec.describe 'Admin::ResidentialComplexes', type: :request do
  include_context 'с админ-токеном'

  describe 'доступ' do
    it 'без токена уводит на форму входа' do
      get admin_residential_complexes_path

      expect(response).to have_http_status(:found)
    end

    it 'с токеном пускает' do
      admin_get admin_residential_complexes_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET index' do
    let!(:published) { create(:residential_complex, :with_body, name: 'Легенда') }
    let!(:draft)     { create(:residential_complex, name: 'Черновик') }
    let!(:removed)   { create(:residential_complex, name: 'Удалённый').tap(&:soft_delete!) }

    it 'по умолчанию скрывает удалённые' do
      admin_get admin_residential_complexes_path

      expect(response.body).to include('Легенда', 'Черновик')
      expect(response.body).not_to include('Удалённый')
    end

    # Без unscoped в контроллере таб был бы пуст, а soft-delete —
    # необратим без консоли.
    it 'таб «удалённые» показывает мягко удалённые' do
      admin_get admin_residential_complexes_path, params: { scope: 'deleted' }

      expect(response.body).to include('Удалённый')
      expect(response.body).not_to include('Черновик')
    end

    # on_site_listings_count мемоизирован per-instance: в цикле по строкам
    # он дал бы запрос на каждую. Считаем SELECT'ы, а не просто статус —
    # иначе возврат к N+1 останется зелёным.
    it 'считает объекты одним запросом, а не по строке' do
      3.times do |i|
        complex = create(:residential_complex, name: "ЖК #{i}")
        create(:property, :on_site, residential_complex: complex)
      end

      queries = 0
      counter = ->(_n, _s, _f, _i, payload) { queries += 1 unless payload[:name] == 'SCHEMA' }

      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        admin_get admin_residential_complexes_path
      end

      # Порог с запасом: важно, что число не растёт линейно от числа ЖК.
      expect(queries).to be < 25
    end
  end

  describe 'POST create' do
    let(:valid_params) do
      {
        residential_complex: {
          name: 'Приокский парк', city: 'Рязань', district_slug: 'priokskiy',
          body_blocks_json: [{ 'kind' => 'paragraph', 'text' => 'Дом сдан в 2021.' }].to_json,
          body_blocks_editor: '1'
        }
      }
    end

    it 'создаёт ЖК и пересобирает проекции блоков' do
      expect { admin_post admin_residential_complexes_path, params: valid_params }
        .to change(ResidentialComplex, :count).by(1)

      complex = ResidentialComplex.last
      expect(complex.slug).to eq('priokskiy-park')
      expect(complex.body_html).to include('Дом сдан в 2021.')
    end

    it 'возвращает 422 на невалидном' do
      admin_post admin_residential_complexes_path,
                 params: { residential_complex: { name: '', city: 'Рязань' } }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'отвергает город вне реестра' do
      admin_post admin_residential_complexes_path,
                 params: { residential_complex: { name: 'Тест', city: 'Тьмутаракань' } }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH update' do
    let(:complex) { create(:residential_complex, name: 'Легенда') }

    it 'нормализует адресные паттерны из textarea' do
      admin_patch admin_residential_complex_path(complex), params: {
        residential_complex: { address_patterns_text: "Костычева, 8\n\n  Костычева, 10  \nКостычева, 8" }
      }

      expect(complex.reload.address_patterns).to eq(['Костычева, 8', 'Костычева, 10'])
    end

    it 'пустая textarea очищает массив' do
      complex.update!(address_patterns: ['Костычева, 8'])

      admin_patch admin_residential_complex_path(complex),
                  params: { residential_complex: { address_patterns_text: '' } }

      expect(complex.reload.address_patterns).to eq([])
    end

    # Гвард — копия из лендингов, и без своей сети следующий, кто «уберёт
    # дублирование», сломает ЖК и не узнает. Ровно этот класс бага стёр
    # контент лендинга в PR #15.
    it 'пустые блоки от НЕ поднявшегося редактора не стирают текст' do
      with_body = create(:residential_complex, :with_body)

      admin_patch admin_residential_complex_path(with_body), params: {
        residential_complex: { body_blocks_json: '[]', body_blocks_editor: '0' }
      }

      with_body.reload
      expect(with_body.body_blocks).to be_present
      expect(with_body.body_html).to be_present
    end

    it 'пустые блоки от живого редактора очищают текст' do
      with_body = create(:residential_complex, :with_body)

      admin_patch admin_residential_complex_path(with_body), params: {
        residential_complex: { body_blocks_json: '[]', body_blocks_editor: '1' }
      }

      expect(with_body.reload.body_blocks).to eq([])
    end

    it 'битый JSON не трогает блоки' do
      with_body = create(:residential_complex, :with_body)
      original = with_body.body_blocks

      admin_patch admin_residential_complex_path(with_body), params: {
        residential_complex: { body_blocks_json: '{oops', body_blocks_editor: '1' }
      }

      expect(with_body.reload.body_blocks).to eq(original)
    end

    it 'пустой enum-селект даёт nil, а не падение' do
      admin_patch admin_residential_complex_path(complex),
                  params: { residential_complex: { housing_class: '', build_status: '' } }

      expect(complex.reload.housing_class).to be_nil
    end
  end

  describe 'жизненный цикл' do
    let(:complex) { create(:residential_complex, :with_body) }

    it 'публикует и снимает с публикации' do
      admin_post unpublish_admin_residential_complex_path(complex)
      expect(complex.reload).not_to be_published

      admin_post publish_admin_residential_complex_path(complex)
      expect(complex.reload).to be_published
    end

    # Решение Фазы 1: soft-delete сохраняет привязку, чтобы ЖК можно было
    # вернуть вместе с объектами. От вьюх удалённый скрыт default_scope.
    it 'мягкое удаление сохраняет привязки объектов' do
      property = create(:property, :on_site, residential_complex: complex)

      admin_post soft_delete_admin_residential_complex_path(complex)

      expect(ResidentialComplex.find_by(id: complex.id)).to be_nil
      expect(property.reload.residential_complex_id).to eq(complex.id)
      expect(property.residential_complex).to be_nil
    end

    it 'восстанавливает черновиком, а не в прежнем статусе' do
      complex.soft_delete!

      admin_post restore_admin_residential_complex_path(complex)

      restored = ResidentialComplex.find_by(id: complex.id)
      expect(restored).to be_present
      expect(restored).not_to be_published
    end
  end

  describe 'привязка объектов' do
    let(:complex) { create(:residential_complex, name: 'Скобелев') }
    let!(:free)   { create(:property, :on_site) }

    it 'привязывает выбранные и двигает updated_at' do
      free.update_columns(updated_at: 3.days.ago)

      expect do
        admin_post attach_properties_admin_residential_complex_path(complex),
                   params: { property_ids: [free.id] }
      end.to change { free.reload.residential_complex_id }.from(nil).to(complex.id)

      # updated_at выставляется руками, потому что update_all минует
      # колбэки; Фаза 4 читает его для sitemap lastmod.
      expect(free.reload.updated_at).to be > 1.hour.ago
    end

    # Симметрия с detach: без скоупа устаревшая форма молча перетащила бы
    # объект у другого ЖК, и прежний потерял бы его без следа.
    it 'не перетаскивает объект, уже привязанный к другому ЖК' do
      other = create(:residential_complex, name: 'Другой ЖК')
      free.update!(residential_complex: other)

      admin_post attach_properties_admin_residential_complex_path(complex),
                 params: { property_ids: [free.id] }

      expect(free.reload.residential_complex_id).to eq(other.id)
      expect(flash[:notice]).to include('Пропущено')
    end

    it 'не привязывает объект, которого нет на сайте' do
      draft = create(:property)

      admin_post attach_properties_admin_residential_complex_path(complex),
                 params: { property_ids: [draft.id] }

      expect(draft.reload.residential_complex_id).to be_nil
    end

    it 'отвязывает только свой объект' do
      other = create(:residential_complex, name: 'Другой ЖК')
      free.update!(residential_complex: other)

      admin_post detach_property_admin_residential_complex_path(complex, property_id: free.id)

      expect(free.reload.residential_complex_id).to eq(other.id)
    end

    it 'экран привязки открывается и объясняет, почему пусто' do
      admin_get listings_admin_residential_complex_path(complex)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('координат')
    end
  end
end
