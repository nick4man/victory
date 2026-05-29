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
                     when 'director', 'admin' then 'директор'
                     when 'manager' then 'руководитель'
                     else 'сотрудник'
                     end
        "📚 <b>Шпаргалка по боту · #{role_label}</b>\n" \
          "<i>Зажми это сообщение и выбери «Закрепить» — будет всегда наверху чата.</i>"
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
          🔍 <b>Поиск (пиши боту в личные сообщения)</b>

          <b>Сообщения рабочего чата</b> (морфология учитывается — «клиент» найдёт «клиенту»):
            • <i>«найди сообщения про Канищево за неделю»</i>
            • <i>«что Ирина писала вчера»</i>
            • <i>«обсуждение в #КВАРТИРЫ за месяц»</i>

          <b>Задачи всех сотрудников</b>:
            • <i>«какие задачи просрочены у всех»</i>
            • <i>«задачи Маши на этой неделе»</i>
            • <i>«срочные открытые задачи»</i>

          <b>Лиды (поиск по описанию + фильтры)</b>:
            • <i>«найди открытые лиды по Солотче»</i>
            • <i>«лиды на стадии показа»</i>
            • <i>«кому Серёга направил лиды за вчера»</i>

          <b>Свой и общий аудит</b>:
            • <i>«что я давала сегодня / вчера / на неделе»</i>
            • <i>«что всё агентство сделало за неделю»</i>
            • <i>«кто лучший за месяц»</i>
            • <i>«у кого больше всего просрочек»</i>
        HTML
      end

      def actions_section
        return nil unless @tg_user.manager_or_director?

        <<~HTML.strip
          ⚡ <b>Действия (номер лида — первым числом в личке)</b>
            <code>/assign 87 @irina</code> — назначить лид Ирине
            <code>/route 87 apartments</code> — перенаправить в #КВАРТИРЫ
            <code>/stage 87 показ</code> — сменить стадию
            <code>/note 87 клиент согласен на 8.2М</code> — заметка в карточку клиента
            <code>/close 87 выиграно</code> — закрыть лид
            <code>/task 87 25.05.26 позвонить</code> — задача с датой

          Узнать номер лида — через <code>/dashboard</code> [🎯] или поиском.

          <b>Управление сотрудниками</b>:
            <code>/promote @user</code> · <code>/demote @user</code>
            <code>/link @user email@victory.ru</code>
            <code>/deactivate @user</code> · <code>/reassign &lt;номер задачи&gt; @user</code>
        HTML
      end

      def photo_section
        <<~HTML.strip
          📷 <b>Фото в личные сообщения</b>
          Пришли фото — бот сразу спросит кнопками:
            <b>☁️ В облако</b> — сохранить в Nextcloud + ссылка на скачивание
            <b>📤 Сотруднику</b> — переслать фото без задачи (с подписью или без)
            <b>✅ С задачей</b> — создать задачу с фото в приложении
        HTML
      end

      def voice_section
        return nil unless @tg_user.can_voice_distribute?

        <<~HTML.strip
          🎙 <b>Голос в личные сообщения</b> (только директор)
          Бот сам поймёт что ты хочешь:
            • <b>Раздать задачи</b> — «передай Ирине: позвонить Анне до 16:00» → пакет задач, надо подтвердить кнопкой
            • <b>Спросить</b> — «какие лиды я направила сегодня?» → бот ответит цифрами
        HTML
      end

      def digest_section
        return nil unless @tg_user.role.in?(%w[director admin])

        <<~HTML.strip
          📅 <b>Приходит автоматически в личку</b>
            <b>Каждый день в 08:30</b> — сводка за вчера (лидер дня, просрочки, важное)
            <b>По понедельникам в 10:00</b> — итоги недели (сравнение с прошлой, отклонения, расход)
            + важные уведомления: просроченные задачи, премиум-лиды, закрытые сделки
        HTML
      end

      def footer
        '<i>На сложные запросы бот думает 5–30 секунд (использует языковую модель). ' \
          'Если видишь «💭 Принял, думаю…» — он работает, скоро ответит.</i>'
      end
    end
  end
end
