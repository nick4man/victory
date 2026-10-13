# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Базовый класс пошагового мастера. Подкласс описывает шаги и финальное
      # действие; хранение состояния, кнопки «Назад/Отмена», повтор шага при
      # ошибке и снятие клавиатур — забота Engine.
      #
      # Шаг — один вопрос. Виды:
      #   :choice  — кнопки; значения опций хранятся в состоянии, в callback_data
      #              уходит только индекс (лимит TG — 64 байта, а значение может
      #              содержать «:»). У choice может быть ручной ввод (manual) —
      #              запасной путь, когда нужного варианта нет в списке.
      #   :input   — свободный текст с проверкой; quick — кнопки готовых ответов.
      #   :confirm — одна кнопка подтверждения перед необратимым действием.
      #
      # Ответ шага пишется в ctx[step.id]. Шаг, чей ключ уже есть в ctx (лид
      # пришёл с кнопкой на карточке), не задаётся вовсе.
      class Flow
        Step = Struct.new(:id, :kind, :prompt, :hint, :options, :quick, :manual,
                          :manual_prompt, :per_row, :confirm_label, keyword_init: true)

        class << self
          attr_reader :key, :title

          def flow(key, title)
            @key = key
            @title = title
          end

          def manager_only(val = true)
            @manager_only = val
          end

          def manager_only?
            @manager_only == true
          end
        end

        attr_reader :tg_user, :ctx, :client

        def initialize(tg_user:, ctx: {}, client: Telegram::Client.new)
          @tg_user = tg_user
          @ctx = ctx.to_h.stringify_keys
          @client = client
        end

        # @return [Array<Step>] все шаги по порядку, с учётом уже данных ответов.
        def steps
          raise NotImplementedError
        end

        # Шаг, который не нужно задавать при текущих ответах (исход «выиграно»
        # не требует причины отказа).
        def skip?(_step)
          false
        end

        # Проверка ответа. Для choice value — выбранное значение опции, для
        # input и manual — сырой текст.
        # @return [Array(Object, String|nil)] [нормализованное значение, текст ошибки]
        def accept(_step, value, manual: false)
          [value, nil]
        end

        # Проверка до первого вопроса — например, лид с карточки уже закрыт.
        # @return [String, nil] текст отказа
        def gate
          nil
        end

        # Финальное действие. Вызывается один раз, после того как Engine снял
        # состояние: повторное нажатие подтверждения сюда не доходит.
        # @return [Hash] { text:, keyboard: [[{text:, callback_data:}]] }
        def finish
          raise NotImplementedError
        end

        protected

        def escape_html(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end

        def manager?
          tg_user&.manager_or_director?
        end
      end
    end
  end
end
