# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::SubmitReview do
  after { Thread.current[:lead_test_mode] = false }

  describe 'тест-режим чат-бота (issue #214)' do
    it 'probe-прогон: инструмент отключён, Review не создаётся, модератор не уведомляется' do
      Thread.current[:lead_test_mode] = true
      expect(ReviewModerationNotifier).not_to receive(:notify)

      result = nil
      expect {
        result = described_class.call(author_name: 'Пробный', rating: 5, body: 'Тестовый отзыв из прогона')
      }.not_to change(Review, :count)

      expect(result[:success]).to be(false)
      expect(result[:error]).to eq('test_mode')
    end

    it 'боевой режим: отзыв создаётся по-прежнему (регрессия)' do
      allow(ReviewModerationNotifier).to receive(:notify)

      expect {
        @result = described_class.call(author_name: 'Клиент', rating: 5, body: 'Хорошее агентство, спасибо!')
      }.to change(Review, :count).by(1)

      expect(@result[:success]).to be(true)
      expect(ReviewModerationNotifier).to have_received(:notify)
    end
  end
end
