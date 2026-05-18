# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Phase 7.2 — Подтверждение / отмена пакета задач Оксаны.
      # callback_data: "batch_confirm:<batch_id>:approve" или "...:cancel"
      #
      # On approve:
      #   1. Загружает TaskBatch + tasks_payload
      #   2. Для каждой задачи в payload создаёт Task запись (assignee_id, title,
      #      due_at, priority, kind, task_batch_id, lead_event_id?)
      #   3. Обновляет batch.confirm! + edits preview message с галочкой
      #   4. (Phase 7.3 добавит TaskDispatcher — DM каждому assignee)
      #
      # On cancel:
      #   1. batch.cancel!
      #   2. Edits preview с маркером ✖️
      class TaskBatchConfirmCallback < Base
        director_only

        def handle
          batch_id = @args[0].to_i
          action   = @args[1].to_s

          batch = TaskBatch.find_by(id: batch_id)
          return ack('⚠️ Batch не найден', alert: true) if batch.nil?

          # Phase 10 Iter 13 — narrow critical section. DB lock держит row
          # ТОЛЬКО для status check + create_tasks_from + confirm! (~50-100ms).
          # TG calls (dispatch_tasks, edit_preview) — outside lock, чтобы
          # другие webhooks не блокировались.
          case action
          when 'approve'
            created = nil
            batch.with_lock do
              batch.reload
              unless batch.status_pending_confirm?
                return ack("ℹ️ Batch уже #{batch.status} — повторное действие невозможно", alert: true)
              end

              created = create_tasks_from(batch)
              batch.confirm!
            end
            # Outside lock — TG operations (slow, can hang) не блокируют batch row.
            post_approve_dispatch!(batch, created)
          when 'cancel'
            batch.with_lock do
              batch.reload
              unless batch.status_pending_confirm?
                return ack("ℹ️ Batch уже #{batch.status} — повторное действие невозможно", alert: true)
              end

              batch.cancel!
            end
            edit_preview(batch, suffix: "\n\n✖️ <b>Отменено</b>")
            ack('✖️ Отменено')
          else
            ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def post_approve_dispatch!(batch, created)
          dispatch_results = dispatch_tasks(created || [])
          edit_preview(batch, suffix: "\n\n✅ <b>Подтверждено</b>. Создано задач: #{created.size}. " \
                                      "DM отправлено: #{dispatch_summary(dispatch_results)}.")

          # Phase 12 Iter 33 — partial dispatch failure → escalate.
          # До этого фикса: 1 task failed DM (assignee заблокировал бота) → silent
          # log warn, batch выглядит «успешно подтверждённым» в preview, но один
          # из агентов task не получил → клиент в ожидании, никто не знает.
          handle_dispatch_failures(batch, created, dispatch_results)

          # Phase 13 Iter 45 — alert director о orphan tasks (assignee=nil после
          # LLM-extract). Эти задачи в БД, но TaskDispatcher group_by skip'ает
          # их — silent void. Директор должен manually edit/reassign.
          handle_orphan_tasks(batch, created)

          ack("✅ Создано задач: #{created.size}")
        end

        # Phase 13 Iter 45 — DM director о tasks без assignee_id.
        def handle_orphan_tasks(batch, created)
          orphans = Array(created).select { |t| t.assignee_id.blank? }
          return if orphans.empty?

          throttle_key = "task_orphan:#{batch.id}"
          return unless Telegram::AlertThrottle.allow?(key: throttle_key)

          lines = orphans.first(10).map { |t| "  • ##{t.id}: #{t.title.to_s.truncate(80)}" }
          lines << "  …+#{orphans.size - 10} more" if orphans.size > 10

          text = "⚠️ <b>TaskBatch ##{batch.id} — #{orphans.size} задач(и) без assignee</b>\n" \
                 "LLM не сматчил никого из staff. Задачи в БД, но DM не уходят " \
                 "(TaskDispatcher пропускает nil assignee).\n\n" \
                 "#{lines.join("\n")}\n\n" \
                 "<i>Назначь вручную через rails console или удали soft-delete'ом.</i>"

          director = batch.created_by
          chat_id = director&.dm_chat_id || director&.tg_user_id
          return if chat_id.blank?

          @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue StandardError => e
          Rails.logger.warn("[TaskBatchConfirmCallback#handle_orphan_tasks] #{e.class}: #{e.message}")
        end

        def handle_dispatch_failures(batch, created, results)
          failures = Array(results).select { |r| r.is_a?(Hash) && r[:error] }
          return if failures.empty?

          # Persist в batch.parsed_payload для будущего /retry_dispatch (Phase 13+)
          batch.update!(
            parsed_payload: batch.parsed_payload.merge(
              'dispatch_failures' => failures.map { |f| f.slice(:assignee, :count, :error) },
              'dispatch_failures_at' => Time.current.iso8601
            )
          )

          alert_directors_about_failures(batch, created, failures)
        rescue StandardError => e
          Rails.logger.warn("[TaskBatchConfirmCallback#handle_dispatch_failures] #{e.class}: #{e.message}")
        end

        def alert_directors_about_failures(batch, created, failures)
          throttle_key = "task_dispatch_fail:#{batch.id}"
          return unless Telegram::AlertThrottle.allow?(key: throttle_key)

          failed_count = failures.sum { |f| f[:count].to_i }
          summary_lines = failures.map { |f| "  • #{f[:assignee]}: #{f[:count]} task(s) — #{f[:error].to_s[0, 80]}" }

          # Phase 13 Iter 49 — surface tier-info на fallback.
          cascade = Telegram::CriticalRecipients.resolve
          tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''

          text = "⚠️ <b>TaskBatch ##{batch.id} — partial dispatch failure</b>\n" \
                 "Создано задач: <b>#{created.size}</b>, не доставлено: <b>#{failed_count}</b>\n\n" \
                 "Сбои:\n#{summary_lines.join("\n")}\n\n" \
                 "<i>Задачи в БД, но assignees не получили DM. Проверь:\n" \
                 "  • Заблокировали ли они бота?\n" \
                 "  • Есть ли у них dm_chat_id (нужно /start от них)?</i>#{tier_note}"

          cascade.each do |recipient|
            chat_id = recipient.dm_chat_id || recipient.tg_user_id
            next if chat_id.blank?

            @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
          rescue StandardError => e
            Rails.logger.warn("[TaskBatchConfirmCallback#alert_directors] DM to #{recipient.mention}: #{e.message}")
          end
        end

        def dispatch_tasks(tasks)
          return [] if tasks.empty?

          Telegram::WorkBot::TaskDispatcher.new(tasks: tasks, client: @client).call
        rescue StandardError => e
          Rails.logger.warn("[TaskBatchConfirmCallback] dispatch failed: #{e.class} #{e.message}")
          []
        end

        def dispatch_summary(results)
          return '0' if results.blank?

          ok = results.count { |r| r.is_a?(Hash) && r[:error].nil? }
          failed = results.count { |r| r.is_a?(Hash) && r[:error] }
          failed.zero? ? ok.to_s : "#{ok} (⚠️ #{failed} fail)"
        end

        # Phase 10 Iter 13 — cancel логика inlined в handle (двойная with_lock
        # секция). Этот метод сохранён как dead-code чтобы тесты не ломались,
        # удалить в следующем рефакторинге.
        def cancel!(batch)
          batch.cancel!
        end

        def create_tasks_from(batch)
          batch.tasks_payload.filter_map do |payload|
            assignee = lookup_assignee(payload[:assignee_username])
            task_attrs = {
              title: payload[:title].to_s.presence || '(без названия)',
              due_at: parse_time(payload[:due_at]),
              status: 'open',
              created_by_id: batch.created_by_id,
              assignee_id: assignee&.id,
              task_batch_id: batch.id,
              priority: payload[:priority].presence || 'normal',
              kind: payload[:kind].presence || 'other',
              assigned_at: Time.current
            }
            next nil if task_attrs[:title] == '(без названия)' && assignee.nil?

            ::Task.create!(task_attrs)
          end
        end

        def lookup_assignee(username)
          return nil if username.blank?

          # rubocop:disable Rails/DynamicFindBy -- custom class method, не Rails dynamic finder
          TelegramUser.find_by_username(username)
          # rubocop:enable Rails/DynamicFindBy
        end

        def parse_time(raw)
          return nil if raw.blank?

          return raw if raw.is_a?(Time) || raw.is_a?(DateTime)

          Time.zone.parse(raw.to_s)
        rescue ArgumentError
          nil
        end

        def edit_preview(batch, suffix:)
          return if batch.preview_message_id.blank? || batch.preview_chat_id.blank?

          original = @cb.dig('message', 'text').to_s
          new_text = "#{original}#{suffix}"
          @client.edit_message_text(new_text,
                                    chat_id: batch.preview_chat_id,
                                    message_id: batch.preview_message_id,
                                    parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[TaskBatchConfirmCallback] edit_preview failed: #{e.message}")
        end
      end
    end
  end
end
