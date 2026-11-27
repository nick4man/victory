# frozen_string_literal: true

module Telegram
  module WorkBot
    # Issue #277 — единый контракт callback_data для постраничной навигации
    # по спискам дашборда и кнопок «Назад» из карточек сущностей.
    #
    # Форматы (лимит Telegram на callback_data — 64 байта):
    #   dashboard:leads:p:<page>  — страница списка лидов
    #   dashboard:staff:p:<page>  — страница списка сотрудников
    #   dashboard:lead:<id>       — карточка лида (соседняя подзадача #277)
    #   dashboard:staff:<id>[:<page>] — карточка сотрудника (соседняя
    #     подзадача #277); <page> — страница списка, откуда пришли, для «Назад»
    #
    # Маркер 'p' отделяет страничную навигацию от карточек:
    # dashboard:staff:p:2 (страница 2) не пересекается с dashboard:staff:123
    # (карточка сотрудника id=123).
    #
    # Карточки лида/сотрудника строят кнопку «Назад» через
    # leads_page_callback / staff_page_callback — возврат на конкретную
    # страницу списка, с которой пришли, а не в начало.
    module DashboardPagination
      # Размер страницы списка (8–10 строк по issue; 8 оставляет место
      # футеру навигации в пределах экрана).
      PAGE_SIZE = 8

      PAGE_MARKER = 'p'
      LIST_SECTIONS = %w[leads staff].freeze

      module_function

      def leads_page_callback(page)
        page_callback('leads', page)
      end

      def staff_page_callback(page)
        page_callback('staff', page)
      end

      def page_callback(section, page)
        "dashboard:#{section}:#{PAGE_MARKER}:#{normalize_page(page)}"
      end

      # Разбор args после префикса dashboard:: ['leads', 'p', '3'] → [:leads, 3].
      # nil — если это не страничная навигация (например dashboard:staff:123).
      def parse_page(args)
        section = args[0].to_s
        return nil unless LIST_SECTIONS.include?(section)
        return nil unless args[1].to_s == PAGE_MARKER

        [section.to_sym, normalize_page(args[2])]
      end

      def normalize_page(value)
        [value.to_i, 1].max
      end

      # Футер списка: ◀️ отсутствует на первой странице, ▶️ — на последней.
      # Средняя кнопка — индикатор «page/total»; её повторный тап рендерит ту
      # же страницу (сортировка детерминирована, выборка не «плывёт»).
      def nav_row(section, page, total_pages)
        row = []
        row << { text: '◀️', callback_data: page_callback(section, page - 1) } if page > 1
        row << { text: "#{page}/#{total_pages}", callback_data: page_callback(section, page) }
        row << { text: '▶️', callback_data: page_callback(section, page + 1) } if page < total_pages
        row
      end
    end
  end
end
