# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::PageGreeting do
  it 'nil — дефолтное приветствие' do
    expect(described_class.for(nil)).to eq(described_class::DEFAULT)
  end

  it 'главная — своё приветствие' do
    expect(described_class.for({ 'path' => '/' })).to include('С чего начнём')
  end

  describe 'ЖК' do
    it 'slug из path достаёт имя комплекса из БД (fallback без ctx)' do
      complex = create(:residential_complex, :published, name: 'Легенда Парк')
      greeting = described_class.for({ 'path' => "/zhk/#{complex.slug}" })
      expect(greeting).to include('Легенда Парк')
    end

    it 'slug из ctx в приоритете; без совпадения в БД — нейтральный текст' do
      greeting = described_class.for({ 'path' => '/zhk/nope-404',
                                       'ctx' => { 'kind' => 'zhk', 'slug' => 'nope-404' } })
      expect(greeting).to include('Смотрите жилой комплекс')
      expect(greeting).not_to include('nil')
    end

    it '/zhk без slug — не вид ЖК, дефолтное приветствие' do
      expect(described_class.for({ 'path' => '/zhk' })).to eq(described_class::DEFAULT)
    end
  end

  describe 'инвест-аудит' do
    it 'форма (/new) — не обещает готовый вердикт' do
      greeting = described_class.for({ 'path' => '/valuations/audit/new',
                                       'ctx' => { 'kind' => 'investment_audit_new' } })
      expect(greeting).to include('инвест-аудит')
      expect(greeting).not_to include('готов')
    end

    it 'pending — «ещё считается», а не «готов»' do
      greeting = described_class.for({ 'path' => '/valuations/audit/t1',
                                       'ctx' => { 'kind' => 'investment_audit', 'state' => 'pending' } })
      expect(greeting).to include('ещё считается')
    end

    it 'failed — предлагает повторить' do
      greeting = described_class.for({ 'path' => '/valuations/audit/t1',
                                       'ctx' => { 'kind' => 'investment_audit', 'state' => 'failed' } })
      expect(greeting).to include('не удался')
    end

    it 'completed — прежний текст про готовый аудит' do
      greeting = described_class.for({ 'path' => '/valuations/audit/t1',
                                       'ctx' => { 'kind' => 'investment_audit', 'state' => 'completed' } })
      expect(greeting).to include('аудит объекта готов')
    end

    it 'без state — нейтральный текст, не «готов»' do
      greeting = described_class.for({ 'path' => '/valuations/audit/t1',
                                       'ctx' => { 'kind' => 'investment_audit' } })
      expect(greeting).not_to include('готов')
    end
  end

  describe 'результат оценки' do
    it 'completed — прежний текст про готовую оценку' do
      greeting = described_class.for({ 'path' => '/valuations/t/result',
                                       'ctx' => { 'kind' => 'valuation_result', 'state' => 'completed' } })
      expect(greeting).to include('оценка готова')
    end

    it 'pending/failed — не «готова»' do
      pending = described_class.for({ 'path' => '/valuations/t/result',
                                      'ctx' => { 'kind' => 'valuation_result', 'state' => 'pending' } })
      expect(pending).to include('ещё считается')

      failed = described_class.for({ 'path' => '/valuations/t/result',
                                     'ctx' => { 'kind' => 'valuation_result', 'state' => 'failed' } })
      expect(failed).to include('не удался')
    end

    it 'без state — нейтральный текст, не «готова»' do
      greeting = described_class.for({ 'path' => '/valuations/t/result',
                                       'ctx' => { 'kind' => 'valuation_result' } })
      expect(greeting).not_to include('готова')
    end
  end
end
