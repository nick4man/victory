# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 15 — генератор cheat-sheet для директора в DM.
    # Структурированный markdown с ВСЕМИ возможностями control panel'и:
    # commands, search queries, KPI tools, push-digest.
    #
    # Используется командой /cheatsheet — manager+ может закрепить ответ
    # в DM с ботом (TG pinChatMessage) как reference card.
    #
    # ~1500 chars текст — умещается в одно TG-сообщение (limit 4096).
    # parse_mode='HTML' с <code>, <i>, <b>.
    class CheatsheetRenderer
      def self.call(tg_user:)
        new(tg_user: tg_user).call
      end

      def initialize(tg_user:)
        @tg_user = tg_user
      end

      def call
        sections = [
          header,
          panel_section,
          search_section,
          actions_section,
          photo_section,
          voice_section,
          digest_section,
          footer
        ]
        sections.compact.join("\n\n")
      end

      private

      def header
        role_label = case @tg_user.role
                     when 'director', 'admin' then 'director'
                     when 'manager' then 'manager'
                     else 'agent'
                     end
        "📚 <b>Cheat-sheet @anvictorybot · #{role_label}</b>\n" \
          "<i>Закрепи это сообщение (long-press → Pin) для быстрого доступа.</i>"
      end

      def panel_section
        return nil unless @tg_user.manager_or_director?

        <<~HTML.strip
          📊 <b>Панель управления</b>
            <code>/dashboard</code> — полная сводка (лиды/задачи/сотрудники/KPI/алерты)
            <code>/panel</code> — alias /dashboard
            Inline-кнопки [🎯][✅][👥][🔍] — drill в секции
        HTML
      end

      def search_section
        return nil unless @tg_user.manager_or_director?

        <<~HTML.strip
          🔍 <b>Поиск (просто пиши боту в DM)</b>

          <b>Сообщения рабочего чата</b> (russian морфология учтена):
            • <i>«найди сообщения про Канищево за неделю»</i>
            • <i>«что Ирина писала вчера»</i>
            • <i>«обсуждение в #КВАРТИРЫ за месяц»</i>

          <b>Задачи (cross-staff)</b>:
            • <i>«какие задачи overdue у всех»</i>
            • <i>«задачи Маши на этой неделе»</i>
            • <i>«high-priority открытые задачи»</i>

          <b>Лиды (FTS + фильтры)</b>:
            • <i>«найди лиды по Солотче открытые»</i>
            • <i>«лиды на стадии показа»</i>
            • <i>«кому Серёга направил лиды за вчера»</i>

          <b>Аудит и KPI</b>:
            • <i>«что я давала сегодня/вчера/на неделе»</i>
            • <i>«что всё АН сделало за неделю»</i>
            • <i>«кто топ-performer за месяц»</i>
            • <i>«у кого аномалии по overdue»</i>
        HTML
      end

      def actions_section
        return nil unless @tg_user.manager_or_director?

        <<~HTML.strip
          ⚡ <b>Действия (lead_id первым аргументом в DM)</b>
            <code>/assign 87 @irina</code> — назначить лид Ирине
            <code>/route 87 apartments</code> — перенаправить в #КВАРТИРЫ
            <code>/stage 87 показ</code> — сменить стадию
            <code>/note 87 клиент согласен на 8.2М</code> — заметка в CRM
            <code>/close 87 выиграно</code> — закрыть лид
            <code>/task 87 25.05.26 позвонить</code> — задача на дату

          Узнать lead_id — через <code>/dashboard</code> [🎯] или search query.

          <b>Управление сотрудниками</b>:
            <code>/promote @user</code> · <code>/demote @user</code>
            <code>/link @user email@victory.ru</code>
            <code>/deactivate @user</code> · <code>/reassign &lt;task_id&gt; @user</code>
        HTML
      end

      def photo_section
        <<~HTML.strip
          📷 <b>Фото в DM</b> (Iter 60-61)
          Шли фото — бот спросит inline-кнопками:
            <b>☁️ В облако</b> — Nextcloud archive с share-link
            <b>📤 Сотруднику</b> — переслать фото в DM без задачи (опц. caption)
            <b>✅ С задачей</b> — создать Task с фото в attachments
        HTML
      end

      def voice_section
        return nil unless @tg_user.can_voice_distribute?

        <<~HTML.strip
          🎙 <b>Голос в DM</b> (Iter 59, director only)
          Бот сам определит intent:
            • <b>task_batch</b> — «передай Ирине: позвонить Анне до 16:00» → пакет задач с inline-кнопками подтверждения
            • <b>query</b> — «какие лиды я направила сегодня?» → search-ответ
        HTML
      end

      def digest_section
        return nil unless @tg_user.role.in?(%w[director admin])

        <<~HTML.strip
          📅 <b>Автоматически приходит в DM</b>
            <b>08:30 MSK ежедневно</b> — сводка за вчера (топ-performer, SLA, alerts)
            <b>Пн 10:00 MSK</b> — недельный отчёт (тренды vs предыдущая неделя, аномалии)
            + push-alerts: SLA breach, high-value лиды, deal closed
        HTML
      end

      def footer
        '<i>Бот не сразу отвечает на сложные запросы (5-30 сек) — LLM-обработка. ' \
          'Видишь «💭 Принял, думаю…» = бот в работе.</i>'
      end
    end
  end
end
