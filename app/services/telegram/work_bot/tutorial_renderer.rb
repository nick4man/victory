# frozen_string_literal: true

module Telegram
  module WorkBot
    # Рендер карточки обучения `/tutorial`: текст урока + inline-клавиатура.
    #
    # Состояние нигде не хранится — номер шага живёт в callback_data
    # (`tutorial:go:3`, 15 байт при лимите Telegram в 64). Поэтому карточка
    # остаётся рабочей и через неделю, а сама она и есть закладка пользователя.
    #
    # Знаменатель («урок 2 из 7») считается по ОТФИЛЬТРОВАННОМУ списку, чтобы
    # агент не видел недостижимых шагов. Индексы на стороне команды и на стороне
    # callback'а считаются от одного и того же списка — иначе понижение роли
    # сдвинуло бы нумерацию.
    class TutorialRenderer
      Result = Struct.new(:markdown, :keyboard, keyword_init: true)

      NAV_HINT = '<i>Карточку не удаляй — вернёшься к любому уроку этими же кнопками.</i>'

      def self.call(tg_user:, index: 0)
        new(tg_user: tg_user).call(index: index)
      end

      # Финальный экран: клавиатура снимается, обучение закрыто.
      def self.finish(tg_user:)
        new(tg_user: tg_user).finish
      end

      def initialize(tg_user:)
        @tg_user = tg_user
        @lessons = TutorialLessons.visible_for(tg_user)
      end

      def call(index: 0)
        return empty_result if @lessons.empty?

        idx = index.to_i.clamp(0, @lessons.size - 1)
        lesson = @lessons[idx]

        Result.new(markdown: card(lesson, idx), keyboard: keyboard(idx))
      end

      def finish
        Result.new(markdown: finish_text, keyboard: { inline_keyboard: [] })
      end

      private

      def card(lesson, idx)
        [
          "📚 <b>Обучение · Урок #{idx + 1} из #{@lessons.size}</b>",
          "<b>#{lesson[:title]}</b>",
          '',
          lesson[:body],
          '',
          NAV_HINT
        ].join("\n")
      end

      def keyboard(idx)
        row = []
        row << { text: '◀️ Назад', callback_data: "tutorial:go:#{idx - 1}" } if idx.positive?
        row << if idx >= @lessons.size - 1
                 { text: '✅ Готово', callback_data: 'tutorial:finish' }
               else
                 { text: 'Далее ▶️', callback_data: "tutorial:go:#{idx + 1}" }
               end

        { inline_keyboard: [row] }
      end

      def finish_text
        <<~HTML.strip
          📚 <b>Обучение пройдено</b>

          Дальше держи под рукой <code>/cheatsheet</code> — там весь синтаксис команд для твоей
          роли. Зажми ответ бота и выбери «Закрепить», чтобы шпаргалка всегда была наверху чата.

          Забыл что-то из уроков — <code>/tutorial</code> откроет курс заново.
        HTML
      end

      # Роль без единого доступного урока — ситуация неожиданная (staff-уроки
      # видны всем зарегистрированным), но карточку без текста слать нельзя.
      def empty_result
        Result.new(
          markdown: '📚 Обучение пока недоступно для твоей роли. Напиши руководителю.',
          keyboard: { inline_keyboard: [] }
        )
      end
    end
  end
end
