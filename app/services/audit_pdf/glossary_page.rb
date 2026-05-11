# frozen_string_literal: true

module AuditPdf
  # Page 4 — risks, assumptions, glossary, contact. Closes the report
  # with everything the regular reader might need to understand the
  # numbers and reach an agent.
  class GlossaryPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, _monte_carlo)
      @doc = doc
      @v = valuation
      @audit = audit || {}
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      risks_assumptions
      glossary
      contact_footer
      page_footer
    end

    private

    def paint_paper
      @doc.canvas do
        @doc.fill_color Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color Theme::INK
    end

    def page_header
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text 'РИСКИ, ПРЕДПОСЫЛКИ, ГЛОССАРИЙ', size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def risks_assumptions
      risks = Array(@audit['risks']).compact_blank
      assumptions = Array(@audit['assumptions']).compact_blank

      if risks.any?
        section_label('РИСКИ И ОГРАНИЧЕНИЯ')
        @doc.move_down 4
        risks.each do |r|
          @doc.text "<color rgb='#{Theme::ACCENT_GOLD}'>▸</color>  #{r}",
                    size: 10.5, inline_format: true, leading: 2
          @doc.move_down 4
        end
        @doc.move_down 10
      end

      if assumptions.any?
        section_label('ПРЕДПОСЫЛКИ РАСЧЁТА')
        @doc.move_down 4
        @doc.fill_color Theme::INK_SOFT
        assumptions.each do |a|
          @doc.text "·  #{a}", size: 9, leading: 2
          @doc.move_down 2
        end
        @doc.fill_color Theme::INK
        @doc.move_down 14
      end
    end

    def glossary
      section_label('СЛОВАРЬ ТЕРМИНОВ')
      @doc.move_down 4

      entries = [
        ['EI (Efficiency Index)',
         'Эффективность инвестиции. Соотношение полезного результата (прогнозная стоимость + сэкономленная аренда) ' \
         'к затратам (платежи по ипотеке или упущенная выгода от других вложений). EI ≥ 1.2 — покупка выгодна; ' \
         '≤ 0.8 — невыгодна.'],
        ['Monte Carlo',
         'Способ оценить разброс будущего: программа разыгрывает миллион вариантов того, как поведут себя цены, ' \
         'ставки и инфляция в горизонте 5 лет, и считает EI для каждого. На выходе мы видим не одно число, ' \
         'а интервал и вероятность хорошего исхода.'],
        ['P(BUY)',
         'Доля сценариев Monte Carlo, в которых EI получился ≥ 1.2. Чем выше — тем устойчивее решение к будущим неопределённостям.'],
        ['Сценарии рынка',
         'Три условных будущих: оптимистичный (низкие ставки, рост цен), реалистичный (текущий прогноз ЦБ РФ) ' \
         'и пессимистичный (высокие ставки, низкий рост). Полезно понимать, в каком из них решение разваливается.'],
        ['Стратегии',
         'Наличные — покупка за свои с дисконтом за полную оплату. Ипотека — покупка с заёмными по текущей рынку. ' \
         'Депозит — НЕ покупать, положить деньги на вклад и арендовать. Лучшая стратегия — у кого выше EI.']
      ]

      entries.each do |term, body|
        @doc.font(Theme::FONT_FAMILY, style: :bold) do
          @doc.text term, size: 10
        end
        @doc.move_down 2
        @doc.fill_color Theme::INK_SOFT
        @doc.font(Theme::FONT_FAMILY, style: :normal) do
          @doc.text body, size: 9, leading: 2, inline_format: true
        end
        @doc.fill_color Theme::INK
        @doc.move_down 10
      end
    end

    def contact_footer
      @doc.move_down 14
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 0.6
      @doc.stroke_horizontal_rule
      @doc.move_down 10

      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text 'ОБСУДИТЬ ОТЧЁТ С АГЕНТОМ', size: 9, character_spacing: 3
      end
      @doc.move_down 6
      contact_lines = [
        AgencyInfo::PHONE_PRIMARY,
        AgencyInfo::PHONE_BACKUP,
        AgencyInfo::EMAIL,
        "#{AgencyInfo::ADDRESS_CITY}, #{AgencyInfo::ADDRESS_STREET}"
      ]
      contact_lines.each do |line|
        @doc.text line, size: 10
        @doc.move_down 2
      end
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      url = AgencyInfo::WEBSITE_URL
      @doc.text "стр. 4  ·  Отчёт #{@v.report_label}  ·  #{url}", size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
