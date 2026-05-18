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
          ack("✅ Создано задач: #{created.size}")
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
