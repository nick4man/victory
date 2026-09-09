# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ZhkObservation do
  let(:attrs) do
    { source: 'erz', external_id: 'erz:564336001', url: 'https://erzrf.ru/x',
      fetched_at: Time.current, payload: { 'name' => 'Скобелев' }, digest: 'a' * 64 }
  end

  it 'не допускает второй записи с тем же digest — на этом стоит идемпотентность' do
    described_class.create!(attrs)

    expect { described_class.create!(attrs) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'допускает то же наблюдение с изменившейся нагрузкой' do
    described_class.create!(attrs)

    expect { described_class.create!(attrs.merge(digest: 'b' * 64)) }.not_to raise_error
  end
end
