# frozen_string_literal: true

# Single source of truth for PDF brand styling. All AuditPdf::*Page modules
# import these constants to stay visually coherent.
#
# Design principle: light "luxury real estate brochure" — cream paper,
# black ink, gold accent rule, generous whitespace. Anti-pattern for printed
# reports is dark background (toner-heavy + bad readability), so we don't
# match the website's dark theme directly — instead we translate the brand
# (monochrome + accent gold + serif/sans pairing) into print conventions.
module AuditPdf
  module Theme
    # === Page geometry ====================================================
    PAGE_MARGIN = 56    # ~20mm on all sides — generous whitespace

    # === Palette (Prawn uppercase hex, no #) ==============================
    PAPER       = 'FAFAF7'   # warm off-white background
    INK         = '1A1A1A'   # near-black body
    INK_SOFT    = '404040'   # secondary body / table cells
    MUTED       = '808080'   # captions, labels, meta
    HAIRLINE    = 'D8D8D8'   # subtle horizontal separators
    TINT        = 'F0EFEA'   # section block tint (slightly darker than paper)
    ACCENT_GOLD = 'B8924A'   # brand accent: wordmark rule, marker dots

    # Verdict block colours — only colour usage on the page; everything
    # else is monochrome + gold.
    VERDICT_BG = {
      'BUY'     => 'DCEDDB',  # mint
      'WAIT'    => 'F4D8DB',  # rose
      'NEUTRAL' => 'F4E6C6'   # cream-amber
    }.freeze
    VERDICT_FG = {
      'BUY'     => '0F5B36',
      'WAIT'    => '8B1A24',
      'NEUTRAL' => '6E4A05'
    }.freeze

    # === Legacy RU labels (kept для backwards compat — новый код использует I18n) ===
    VERDICT_RU  = { 'BUY' => 'ПОКУПАТЬ', 'WAIT' => 'ПОДОЖДАТЬ', 'NEUTRAL' => 'НЕЙТРАЛЬНО' }.freeze
    STRATEGY_RU = { 'cash' => 'Наличными', 'mortgage' => 'Ипотека', 'deposit' => 'Депозит',
                    'Cash' => 'Наличные', 'Mortgage' => 'Ипотека', 'Deposit' => 'Депозит' }.freeze
    CONFIDENCE_RU = { 'high' => 'высокая уверенность', 'medium' => 'средняя уверенность',
                      'low' => 'низкая уверенность' }.freeze

    # === Font paths =======================================================
    FONT_PATH       = Rails.root.join('app/assets/fonts/DejaVuSans.ttf').to_s
    FONT_BOLD_PATH  = Rails.root.join('app/assets/fonts/DejaVuSans-Bold.ttf').to_s
    FONT_FAMILY     = 'DejaVu'

    # === Reusable Prawn helpers (mixed in via `extend Theme::Helpers`) =====
    module Helpers
      # 8pt caps-tracked section label.
      def section_label(text)
        @doc.fill_color Theme::MUTED
        @doc.font(Theme::FONT_FAMILY, style: :bold) do
          @doc.text text, size: 8, character_spacing: 3
        end
        @doc.fill_color Theme::INK
        @doc.move_down 6
      end

      # Plain-Russian explainer box ("Что это значит" style) — gold marker
      # plus dim text. Stays one-paragraph so it doesn't crowd numbers.
      def explainer(text)
        @doc.font(Theme::FONT_FAMILY, style: :normal) do
          @doc.fill_color Theme::ACCENT_GOLD
          @doc.text "▸ ", size: 9, inline_format: true
        end
        @doc.move_cursor_to(@doc.cursor + 11)  # tuck the label upward
        @doc.fill_color Theme::INK_SOFT
        @doc.font(Theme::FONT_FAMILY, style: :normal) do
          @doc.indent(14) do
            @doc.text text, size: 9, leading: 2
          end
        end
        @doc.fill_color Theme::INK
        @doc.move_down 8
      end

      # Russian-formatted rouble amount with space separators.
      def fmt_rub(v)
        return '—' if v.blank?
        "#{v.to_f.round.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse} ₽"
      end

      # RUB + USD pair для foreign audits. @rates установлен в page module
      # из generator (PropertyValuation.metadata snapshot или live).
      # Formula: usd = rub / rates[:usd] (CBR.ru curve).
      def fmt_rub_usd(v)
        return '—' if v.blank?
        rub = fmt_rub(v)
        rates = instance_variable_defined?(:@rates) ? @rates : nil
        return rub if rates.blank? || rates[:usd].blank?
        usd = (v.to_f / rates[:usd].to_f).round
        "#{rub} / $#{usd.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}"
      end

      def fmt_pct(v, digits = 1)
        return '—' if v.blank?
        "#{v.to_f.round(digits)}%"
      end

      def fmt_ei(v)
        return '—' if v.blank?
        v.to_f.round(2).to_s
      end

      # i18n-aware verdict label: BUY → «ПОКУПАТЬ» / «BUY». Reads
      # audit.verdicts.<code> через I18n.with_locale wrapper в generator.
      def verdict_label(code)
        key = "audit.verdicts.#{code.to_s.downcase}"
        I18n.t(key, default: Theme::VERDICT_RU[code.to_s] || code.to_s)
      end

      # i18n-aware strategy label.
      def strategy_label(code)
        key = "audit.strategies.#{code.to_s.downcase}"
        I18n.t(key, default: Theme::STRATEGY_RU[code.to_s] || code.to_s.capitalize)
      end

      def confidence_label(code)
        key = "audit.confidence.#{code.to_s.downcase}"
        I18n.t(key, default: Theme::CONFIDENCE_RU[code.to_s] || code.to_s)
      end

      # Legacy aliases — старые page modules могут вызывать verdict_ru/strategy_ru
      # напрямую. Они теперь locale-aware (читают current I18n.locale).
      def verdict_ru(code) = verdict_label(code)
      def strategy_ru(code) = strategy_label(code)
    end
  end
end
