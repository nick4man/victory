# frozen_string_literal: true

require 'rails_helper'

# Регрессия на извлечение RendersLandingBlocks (08.08.26): механика
# пре-рендера body_html/body_plain переехала из LandingContent в общий
# concern, чтобы её мог переиспользовать ResidentialComplex. Поведение
# живого прод-кода при этом меняться не должно — это единственная правка
# существующей модели в Фазе 1.
RSpec.describe LandingContent do
  def build_content(attrs = {})
    described_class.new({
      intent: 'sale',
      type: 'kvartira',
      district_slug: 'kanishchevo',
      title: 'Купить квартиру в Канищево'
    }.merge(attrs))
  end

  describe 'пре-рендер блоков на save' do
    it 'заполняет body_html и body_plain из body_blocks' do
      content = build_content(body_blocks: [
                                { 'kind' => 'heading',   'text' => 'Канищево' },
                                { 'kind' => 'paragraph', 'text' => 'Крупный спальный микрорайон.' }
                              ])
      content.save!

      expect(content.body_html).to include('<h2>Канищево</h2>')
      expect(content.body_html).to include('<p>Крупный спальный микрорайон.</p>')
      expect(content.body_plain).to eq("Канищево\n\nКрупный спальный микрорайон.")
    end

    it 'перерендеривает обе проекции при изменении блоков' do
      content = build_content(body_blocks: [{ 'kind' => 'paragraph', 'text' => 'Старый текст.' }])
      content.save!

      content.update!(body_blocks: [{ 'kind' => 'paragraph', 'text' => 'Новый текст.' }])

      expect(content.body_html).to include('Новый текст.')
      expect(content.body_html).not_to include('Старый текст.')
      expect(content.body_plain).to eq('Новый текст.')
    end

    it 'не трогает проекции, когда блоки не менялись' do
      content = build_content(body_blocks: [{ 'kind' => 'paragraph', 'text' => 'Текст.' }])
      content.save!
      content.update_columns(body_html: '<p>ручная правка</p>')

      content.update!(title: 'Другой заголовок')

      expect(content.reload.body_html).to eq('<p>ручная правка</p>')
    end

    it 'экранирует пользовательский ввод — админский текст не html_safe' do
      content = build_content(body_blocks: [{ 'kind' => 'paragraph', 'text' => '<script>alert(1)</script>' }])
      content.save!

      expect(content.body_html).not_to include('<script>')
      expect(content.body_html).to include('&lt;script&gt;')
    end
  end

  describe '#public_path' do
    it 'собирает URL лендинга района' do
      expect(build_content.public_path).to eq('/kupit/kvartira/rayon/kanishchevo')
    end

    it 'использует /snyat для аренды и суффикс -komnatnaya для комнатности' do
      content = build_content(intent: 'rent', district_slug: nil, rooms: '2')

      expect(content.public_path).to eq('/snyat/kvartira/2-komnatnaya')
    end
  end
end
