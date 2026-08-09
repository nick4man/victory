# frozen_string_literal: true

require 'rails_helper'

# Регресс на потерю контента в блок-редакторе (09.08.26).
#
# Редактор читал начальные блоки через `document.currentScript.dataset`
# внутри <script type="module">, где currentScript по спеке всегда null.
# TypeError глотался пустым catch, STATE.blocks оставался пустым, и
# финальный render() → commit() записывал в скрытое поле '[]'. Контроллер
# это '[]' принимал и перетирал body_blocks, а RendersLandingBlocks
# обнулял body_html/body_plain. В проде под ударом было 20 опубликованных
# лендингов: первое же «Сохранить» стёрло бы текст.
#
# После починки начальное состояние едет в `value` того самого скрытого
# поля, которое редактор сериализует. Поэтому проверять браузером нечего:
# достаточно убедиться, что сервер кладёт в это поле настоящие блоки, а
# контроллер не затирает их пустым массивом от не загрузившегося JS.
RSpec.describe 'Admin::LandingContents', type: :request do
  include_context 'с админ-токеном'

  # response.parsed_body для HTML отдаёт Nokogiri-документ.
  def blocks_json_field
    response.parsed_body.at_css('#lc-blocks-json')
  end

  describe 'доступ' do
    it 'без токена уводит на форму входа' do
      get admin_landing_contents_path

      expect(response).to have_http_status(:found)
      expect(response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
    end

    it 'с токеном пускает' do
      admin_get admin_landing_contents_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'GET /admin/landing_contents/:id/edit' do
    let(:content) { create(:landing_content, :with_blocks) }

    it 'кладёт существующие блоки в value скрытого поля' do
      admin_get edit_admin_landing_content_path(content)

      field = blocks_json_field
      expect(field).to be_present
      expect(JSON.parse(field['value'])).to eq(content.body_blocks)
    end

    it 'переживает кавычки, апострофы, амперсанды и </script> в тексте блока' do
      tricky = create(:landing_content, :with_tricky_text)

      admin_get edit_admin_landing_content_path(tricky)

      field = blocks_json_field
      expect(JSON.parse(field['value'])).to eq(tricky.body_blocks)
    end

    # Страховка от возврата дефекта копипастой.
    it 'не использует data-lc-initial и document.currentScript' do
      admin_get edit_admin_landing_content_path(content)

      expect(response.body).not_to include('data-lc-initial')
      expect(response.body).not_to include('document.currentScript')
    end

    it 'рендерит ровно одно поле блоков' do
      admin_get edit_admin_landing_content_path(content)

      expect(response.parsed_body.css('#lc-blocks-json').size).to eq(1)
    end
  end

  describe 'GET /admin/landing_contents/new' do
    it 'отдаёт пустой массив блоков — поведение новой записи не менялось' do
      admin_get new_admin_landing_content_path

      expect(JSON.parse(blocks_json_field['value'])).to eq([])
    end
  end

  describe 'PATCH /admin/landing_contents/:id' do
    let(:content) { create(:landing_content, :with_blocks) }

    it 'не трогает блоки, когда форма вернула их без изменений' do
      original = content.body_blocks

      admin_patch admin_landing_content_path(content), params: {
        landing_content: {
          title: 'Новый заголовок',
          body_blocks_json: original.to_json,
          body_blocks_editor: '1'
        }
      }

      content.reload
      expect(content.title).to eq('Новый заголовок')
      expect(content.body_blocks).to eq(original)
      expect(content.body_html).to include('О районе')
    end

    it 'сохраняет новые блоки и пересобирает проекции' do
      admin_patch admin_landing_content_path(content), params: {
        landing_content: {
          body_blocks_json: [{ 'kind' => 'paragraph', 'text' => 'Совсем другой текст.' }].to_json,
          body_blocks_editor: '1'
        }
      }

      content.reload
      expect(content.body_blocks.size).to eq(1)
      expect(content.body_html).to include('Совсем другой текст.')
      expect(content.body_plain).to eq('Совсем другой текст.')
    end

    it 'позволяет живому редактору удалить все блоки' do
      admin_patch admin_landing_content_path(content), params: {
        landing_content: { body_blocks_json: '[]', body_blocks_editor: '1' }
      }

      expect(content.reload.body_blocks).to eq([])
    end

    # Ядро регресса: POST от не загрузившегося редактора не должен стирать текст.
    it 'игнорирует пустой массив без маркера живого редактора' do
      original = content.body_blocks

      admin_patch admin_landing_content_path(content), params: {
        landing_content: { title: 'Правка заголовка', body_blocks_json: '[]' }
      }

      content.reload
      expect(content.body_blocks).to eq(original)
      expect(content.body_html).to include('О районе')
      expect(content.title).to eq('Правка заголовка')
    end
  end

  describe 'POST /admin/landing_contents' do
    it 'создаёт запись с блоками' do
      expect do
        admin_post admin_landing_contents_path, params: {
          landing_content: {
            intent: 'sale', type: 'dom', district_slug: 'solotcha',
            title: 'Купить дом в Солотче',
            body_blocks_json: [{ 'kind' => 'paragraph', 'text' => 'Дачное направление.' }].to_json,
            body_blocks_editor: '1'
          }
        }
      end.to change(LandingContent, :count).by(1)

      expect(LandingContent.last.body_html).to include('Дачное направление.')
    end
  end
end
