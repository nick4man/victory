# frozen_string_literal: true

module Chat
  # Общее для контроллеров чат-виджета разрешение тест-контура (issue #249):
  # сигналы (probe-cookie #228 → кран ENV → доверенный origin/IP) собирает
  # Chat::TestMode; здесь — перенос маркера в metadata Conversation.
  module TestModeResolution
    extend ActiveSupport::Concern

    private

    def chat_test_mode_result
      @chat_test_mode_result ||= Chat::TestMode.new(
        request:      request,
        probe_cookie: current_visitor_probe?
      ).call
    end

    def chat_test_mode?
      chat_test_mode_result.test?
    end

    # metadata нового диалога: маркер тест-контура + причина (для разбора,
    # каким сигналом визит попал в тест).
    def conversation_test_metadata
      return {} unless chat_test_mode?

      { 'test_probe' => true, 'test_reason' => chat_test_mode_result.reason }
    end

    # Диалог мог быть создан до включения контура (кран подняли на стенде
    # посреди разговора) — дорисовываем маркер один раз. update_columns, как
    # в stamp_page: без callbacks/validations, metadata — единственная цель.
    def ensure_conversation_test_mode!(conv)
      return unless chat_test_mode?

      meta = conv.metadata.is_a?(Hash) ? conv.metadata.dup : {}
      return if meta['test_probe'] == true

      conv.update_columns(
        metadata: meta.merge('test_probe' => true, 'test_reason' => chat_test_mode_result.reason)
      )
    end
  end
end
