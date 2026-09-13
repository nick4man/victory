# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Исполнитель мастеров: кнопка → вопрос → проверка.
      #
      # Ни одно действие не начинается с печати аргументов. Мастер стартует
      # кнопкой на карточке лида, из меню «Что сделать?» или командой без
      # аргументов и дальше всегда идёт в личке с ботом — в группе переписка
      # с каждым сотрудником засорила бы топик.
      #
      # Состояние — TelegramUser#pending_action (type 'wizard'), тот же механизм,
      # что у фото-сценариев:
      #   { flow:, step:, ctx: {…ответы…}, trail: [id отвеченных шагов],
      #     options: [значения кнопок текущего шага], manual: bool, prompt_id: }
      #
      # Инварианты:
      #   * права проверяются на входе, до первого вопроса;
      #   * ошибка ввода не отменяет мастер — тот же шаг задаётся ещё раз
      #     с разбором, что не так, прежние ответы сохранены;
      #   * нажатие на кнопку устаревшего шага не применяется молча, а
      #     объясняется (двойной клик по «Подтвердить» не создаст два действия);
      #   * клавиатура отвеченного вопроса снимается, чтобы по ней нельзя было
      #     ткнуть повторно.
      #
      # callback_data (префикс `wiz`, разбирает Callbacks::WizardCallback):
      #   wiz:s:<flow>[:<id>]        старт, id — лид или задача с карточки
      #   wiz:p:<flow>:<step>:<idx>  выбор варианта
      #   wiz:m:<flow>:<step>        ручной ввод вместо выбора
      #   wiz:b:<flow>               назад
      #   wiz:x                      отмена
      #   wiz:menu                   меню «Что сделать?»
      class Engine
        STATE_TYPE = 'wizard'
        TTL = 30.minutes

        FLOWS = {
          'task' => 'Telegram::WorkBot::Wizard::TaskFlow',
          'close' => 'Telegram::WorkBot::Wizard::CloseFlow',
          'reopen' => 'Telegram::WorkBot::Wizard::ReopenFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task' }.freeze

        def self.flow_class(key)
          FLOWS[key.to_s]&.constantize
        end

        attr_reader :tg_user, :client

        def initialize(tg_user:, client: Telegram::Client.new)
          @tg_user = tg_user
          @client = client
        end

        def self.active?(tg_user)
          tg_user&.pending_action&.dig('type') == STATE_TYPE
        end

        # @param seed [Hash] ответы, известные заранее (лид с карточки)
        # @return [Symbol] :started | :denied | :gated | :dm_unavailable | :unknown_flow
        def start(flow_key, seed: {})
          klass = self.class.flow_class(flow_key)
          return :unknown_flow unless klass

          if klass.manager_only? && !tg_user.manager_or_director?
            send_dm("🚫 «#{klass.title}» доступно только руководителям.\n" \
                    '<i>Права проверяются до первого вопроса — данные не собираются впустую.</i>',
                    keyboard: [menu_row])
            return :denied
          end

          flow = klass.new(tg_user: tg_user, ctx: seed, client: client)
          if (refusal = flow.gate)
            send_dm(refusal, keyboard: [menu_row])
            return :gated
          end

          strip_previous_prompt
          state = { 'flow' => klass.key, 'ctx' => flow.ctx, 'trail' => [] }
          render_next(flow, state) ? :started : :dm_unavailable
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[Wizard::Engine#start] DM to #{tg_user.mention} failed: #{e.message}")
          :dm_unavailable
        end

        # @return [Symbol] :ok | :stale
        def pick(flow_key, step_id, index)
          state = current_state(flow_key, step_id)
          return :stale unless state && index.to_s.match?(/\A\d+\z/)

          value = Array(state['options'])[index.to_i]
          return :stale if value.nil?

          flow = build_flow(state)
          step = find_step(flow, step_id)
          return :stale unless step

          apply_answer(flow, state, step, value, manual: false)
          :ok
        end

        # Переключает choice-шаг в режим ручного ввода.
        def ask_manual(flow_key, step_id)
          state = current_state(flow_key, step_id)
          return :stale unless state

          flow = build_flow(state)
          step = find_step(flow, step_id)
          return :stale unless step&.manual

          state['manual'] = true
          strip_prompt(state)
          sent = send_dm("#{step.manual_prompt}\n<i>#{escape_html(step.hint)}</i>", keyboard: [nav_row(state)])
          save(state, sent)
          :ok
        end

        # Текстовый ответ в личке. nil — сообщение не для мастера.
        # @return [Symbol, nil]
        def text(raw)
          state = tg_user.pending_action
          return nil unless state && state['type'] == STATE_TYPE

          state = state['data'].to_h.deep_stringify_keys
          flow = build_flow(state)
          step = flow && find_step(flow, state['step'])
          return nil unless step

          value = raw.to_s.strip
          if step.kind == :input || (step.kind == :choice && step.manual && state['manual'])
            apply_answer(flow, state, step, value, manual: step.kind == :choice)
          else
            send_dm('Сейчас нужен выбор кнопкой — свободный текст на этом шаге не принимается.')
          end
          :handled
        end

        def back(flow_key)
          state = current_state(flow_key, nil)
          return :stale unless state

          flow = build_flow(state)
          last = state['trail'].pop
          state['ctx'].delete(last) if last
          state.delete('manual')
          strip_prompt(state)
          render_next(build_flow(state) || flow, state)
          :ok
        end

        def cancel
          state = tg_user.pending_action
          return :stale unless state && state['type'] == STATE_TYPE

          strip_prompt(state['data'].to_h.deep_stringify_keys)
          tg_user.clear_pending_action!
          send_dm('✖️ Мастер отменён. Ничего не сохранено.', keyboard: [menu_row])
          :ok
        end

        def menu
          send_dm(Menu.text(tg_user), keyboard: Menu.keyboard(tg_user))
        end

        private

        def apply_answer(flow, state, step, value, manual:)
          normalized, error = flow.accept(step, value, manual: manual)
          if error
            strip_prompt(state)
            # Кнопки рисуются заново из текущих данных — значения под ними тоже.
            state['options'] = option_values(step)
            sent = send_dm("⚠️ <b>#{error}</b>\n<i>Шаг не сброшен: ответь ещё раз, предыдущие ответы сохранены.</i>",
                           keyboard: step_keyboard(flow, step, state))
            save(state, sent)
            return
          end

          strip_prompt(state)
          state['ctx'][step.id] = normalized
          state['trail'] << step.id
          state.delete('manual')
          render_next(build_flow(state), state)
        end

        # Задаёт первый неотвеченный шаг или завершает мастер.
        # @return [Boolean] удалось ли отправить сообщение
        def render_next(flow, state)
          step = flow.steps.find { |s| !state['ctx'].key?(s.id) && !flow.skip?(s) }
          return finish(flow, state) unless step

          state['step'] = step.id
          state['options'] = option_values(step)
          sent = send_dm(prompt_text(step), keyboard: step_keyboard(flow, step, state))
          return false unless sent

          save(state, sent)
          true
        end

        def finish(flow, state)
          # Второй параллельный апдейт (двойной тап, повтор вебхука) проиграл
          # захват состояния — действие уже выполняет первый.
          return true unless claim_state!(state)

          result = begin
            flow.finish
          rescue StandardError => e
            Rails.logger.error("[Wizard::Engine#finish] #{flow.class.key}: #{e.class}: #{e.message}")
            { text: "⚠️ «#{flow.class.title}» завершился с ошибкой: #{escape_html(e.message.to_s.truncate(150))}\n" \
                    '<i>Проверь, применилось ли действие, прежде чем повторять.</i>' }
          end
          send_dm(result[:text], keyboard: Array(result[:keyboard]) + [menu_row])
          true
        end

        # Атомарно снимает состояние, если оно всё ещё на этом шаге этого
        # мастера. Читать pending_action и потом очищать нельзя: апдейты
        # Telegram обрабатываются параллельно, и оба нажатия на последнюю
        # кнопку успели бы прочитать одно и то же состояние — два действия.
        # @return [Boolean] true — финал выполняет этот вызов
        def claim_state!(state)
          claimed = ::TelegramUser.where(id: tg_user.id)
                                  .where("dm_pending_action->>'type' = ?", STATE_TYPE)
                                  .where("dm_pending_action->'data'->>'flow' = ?", state['flow'])
                                  .where("dm_pending_action->'data'->>'step' = ?", state['step'])
                                  .update_all(dm_pending_action: {})
          tg_user.dm_pending_action = {}
          claimed == 1
        end

        def option_values(step)
          case step.kind
          when :confirm then ['yes']
          when :input   then Array(step.quick).map(&:last)
          else Array(step.options).map(&:last)
          end
        end

        def prompt_text(step)
          text = step.prompt.to_s.lines.map(&:chomp)
          text[0] = "<b>#{text[0]}</b>" if text[0]
          text << "<i>#{escape_html(step.hint)}</i>" if step.hint.present?
          text.join("\n")
        end

        def step_keyboard(flow, step, state)
          rows = []
          case step.kind
          when :choice
            buttons = Array(step.options).each_with_index.map { |(label, _), i| button(label, flow, step, i) }
            rows.concat(buttons.each_slice(step.per_row || 2).to_a)
            rows << [{ text: step.manual, callback_data: "wiz:m:#{flow.class.key}:#{step.id}" }] if step.manual
          when :confirm
            rows << [button(step.confirm_label, flow, step, 0)]
          when :input
            quick = Array(step.quick).each_with_index.map { |(label, _), i| button(label, flow, step, i) }
            rows << quick if quick.any?
          end
          rows << nav_row(state)
          rows
        end

        def button(label, flow, step, index)
          { text: label, callback_data: "wiz:p:#{flow.class.key}:#{step.id}:#{index}" }
        end

        def nav_row(state)
          row = []
          row << { text: '← Назад', callback_data: "wiz:b:#{state['flow']}" } if state['trail'].present?
          row << { text: '✖️ Отмена', callback_data: 'wiz:x' }
          row
        end

        def menu_row
          [{ text: '☰ Что сделать?', callback_data: 'wiz:menu' }]
        end

        # Состояние, к которому относится нажатая кнопка. nil — кнопка от
        # другого мастера или от уже пройденного шага.
        def current_state(flow_key, step_id)
          pa = tg_user.pending_action
          return nil unless pa && pa['type'] == STATE_TYPE

          state = pa['data'].to_h.deep_stringify_keys
          return nil unless state['flow'] == flow_key.to_s
          return nil if step_id && state['step'] != step_id.to_s

          state['ctx'] ||= {}
          state['trail'] ||= []
          state
        end

        def build_flow(state)
          klass = self.class.flow_class(state['flow'])
          klass&.new(tg_user: tg_user, ctx: state['ctx'], client: client)
        end

        def find_step(flow, step_id)
          flow.steps.find { |s| s.id == step_id.to_s }
        end

        def save(state, sent)
          state['prompt_id'] = sent['message_id'] if sent.is_a?(Hash) && sent['message_id']
          tg_user.set_pending_action!(type: STATE_TYPE, data: state, step: state['step'], ttl: TTL)
        end

        def strip_previous_prompt
          pa = tg_user.pending_action
          return unless pa && pa['type'] == STATE_TYPE

          strip_prompt(pa['data'].to_h.deep_stringify_keys)
        end

        # Снимает кнопки с последнего вопроса. Сбой не критичен: устаревшую
        # кнопку всё равно отсечёт current_state.
        def strip_prompt(state)
          return if state['prompt_id'].blank?

          client.edit_message_reply_markup(chat_id: dm_chat_id, message_id: state['prompt_id'],
                                           reply_markup: { inline_keyboard: [] })
        rescue StandardError => e
          Rails.logger.info("[Wizard::Engine#strip_prompt] #{e.class}: #{e.message}")
        end

        def send_dm(text, keyboard: nil)
          return nil if dm_chat_id.blank?

          opts = { chat_id: dm_chat_id, parse_mode: 'HTML' }
          opts[:reply_markup] = { inline_keyboard: keyboard } if keyboard.present?
          client.send_message(text, **opts)
        end

        def dm_chat_id
          tg_user.dm_chat_id || tg_user.tg_user_id
        end

        def escape_html(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
