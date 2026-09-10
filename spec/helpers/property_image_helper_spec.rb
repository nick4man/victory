# frozen_string_literal: true

require 'rails_helper'

# Размеры og:image объявляются по фактическому результату resize_to_limit,
# а не по его рамке. Проверяется здесь, а не прогоном страницы: правило
# общее для трёх вьюх (карточка объекта, district-лендинг, ЖК), а промах
# виден только на нестандартных пропорциях исходника.
RSpec.describe PropertyImageHelper, type: :helper do
  describe '#property_og_image_dimensions' do
    # Настоящий ActiveStorage тут не нужен: метод читает ровно
    # `image.blob.metadata`, и подмена этой пары держит спек быстрым.
    def image_with(metadata)
      blob = Struct.new(:metadata).new(metadata)
      Struct.new(:blob).new(blob)
    end

    it 'у ландшафтного 4:3 совпадает с рамкой' do
      dims = helper.property_og_image_dimensions(image_with('width' => 4000, 'height' => 3000))

      expect(dims).to eq([1920, 1440])
    end

    it 'у портрета упирается в высоту, а не в ширину' do
      dims = helper.property_og_image_dimensions(image_with('width' => 1000, 'height' => 1500))

      expect(dims).to eq([960, 1440])
    end

    it 'у 16:9 упирается в ширину' do
      dims = helper.property_og_image_dimensions(image_with('width' => 3840, 'height' => 2160))

      expect(dims).to eq([1920, 1080])
    end

    # resize_to_limit не растягивает — исходник мельче рамки уходит как есть.
    it 'не увеличивает мелкий исходник' do
      dims = helper.property_og_image_dimensions(image_with('width' => 800, 'height' => 600))

      expect(dims).to eq([800, 600])
    end

    # AnalyzeJob асинхронный: сразу после загрузки метаданных ещё нет.
    it 'nil, пока блоб не проанализирован' do
      expect(helper.property_og_image_dimensions(image_with({}))).to be_nil
    end

    it 'nil на объекте без блоба, а не исключение' do
      expect(helper.property_og_image_dimensions(nil)).to be_nil
    end
  end
end
