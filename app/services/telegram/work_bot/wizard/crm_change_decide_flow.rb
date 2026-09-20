# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор решает по заявке на правку опубликованной карточки.
      # Отклонение требует комментария: автор должен понимать, почему нет.
      class CrmChangeDecideFlow < Flow
        include CrmCardSupport

        flow 'crm_change', 'Решение по правке карточки'

        COMMENT_MIN = 5
        COMMENT_MAX = 500
        VERDICTS = { 'approved' => 'принята', 'rejected' => 'отклонена' }.freeze

        def steps
          list = [Flow::Step.new(id: 'verdict', kind: :choice, per_row: 1, prompt: verdict_prompt,
                                 options: [['✅ Принять правку', 'approve'],
                                           ['↩️ Отклонить', 'reject']])]
          return list unless ctx['verdict'] == 'reject'

          list << Flow::Step.new(id: 'comment', kind: :input, prompt: 'Почему отклоняем?',
                                 hint: 'Автор увидит это дословно.')
        end

        def gate
          return '⚠️ Заявка на правку не найдена.' unless request
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Решение по заявке на правку принимает модератор.' unless permissions.can?(:moderate)
          return "ℹ️ По этой заявке решение уже принято: #{VERDICTS[request.status]}." unless request.status_pending?

          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'comment'

          text = value.to_s.strip
          return [nil, "Слишком коротко: нужно от #{COMMENT_MIN} символов."] if text.length < COMMENT_MIN
          return [nil, "Слишком длинно: #{text.length} симв., влезает #{COMMENT_MAX}."] if text.length > COMMENT_MAX

          [text, nil]
        end

        def finish
          return { text: '⚠️ Заявка на правку не найдена.' } unless request

          service = ::CrmCards::ChangeRequests.new(notifier: ::CrmCards::Notifier.new(client: client))
          result = if ctx['verdict'] == 'approve'
                     service.approve!(request, actor: tg_user)
                   else
                     service.reject!(request, actor: tg_user, comment: ctx['comment'])
                   end
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          ::CrmCards::CardView.render(request.crm_card.reload, viewer: tg_user)
        end

        private

        # ctx['request'] — id заявки, а не карточки: у CrmCardSupport#card свой
        # ключ, и подменять его чужим числом нельзя — он молча вернул бы чужую
        # карточку с тем же номером.
        def request
          return @request if defined?(@request)

          found = ::CrmCardChangeRequest.find_by(id: ctx['request'].to_s[/\A\d+\z/])
          # Карточка песочницы решается в тестовом боте, боевая — в рабочем.
          @request = found if found && found.crm_card.sandbox? == ::Telegram::BotContext.test?
        end

        def verdict_prompt
          return '' unless request

          field = ::CrmCards::Schema.field(request.crm_card.kind, request.field)
          was = ::CrmCards::CardView.plain_value(field, request.old_value) if field
          now = ::CrmCards::CardView.plain_value(field, request.new_value) if field
          "Карточка ##{request.crm_card_id} уже в CRM. #{escape_html(request.author.mention)} просит изменить " \
            "«#{escape_html(field&.label || request.field)}»:\nбыло «#{escape_html(was.to_s)}» → " \
            "стало «#{escape_html(now.to_s)}»."
        end
      end
    end
  end
end
