# frozen_string_literal: true

module Services
  # /services/mortgage — interactive calculator + 22 bank programs catalog
  # + cross-links to investment audit and Express valuation. Replaces the
  # previous coming_soon stub; the calculator is the third pillar of our
  # "stoit li pokupat" → "skolko platit" → "stoit li ipoteka" pipeline.
  #
  # Data flow:
  #   - MacroRatesService.call  → current CB-RF derived rates (used as
  #     defaults + ↻ "use current" button in form)
  #   - Mortgage::ProgramsService.all → 22+ seeded bank programs cached 6h
  #   - Property.friendly.find(from_property) → optional pre-fill from
  #     a property page CTA (B.2 cross-link)
  #
  # /calculate POST remains (returns JSON) — used by the chat-bot tool and
  # any third-party callers. The on-page calculator computes annuity
  # client-side via inline JS (importmap-rails is disabled in this project).
  class MortgageCalculatorsController < ApplicationController
    include ComingSoonSection

    def show
      @macro            = safe_macro
      @programs         = Mortgage::ProgramsService.all
      @deposit_programs = Deposit::ProgramsService.all
      @source_property  = lookup_property(params[:from_property])
      @form_state       = build_form_state
      @faq              = faq_items

      set_meta_tags(
        title:       'Ипотечный калькулятор онлайн — Рязань 2026',
        description: 'Рассчитайте платёж по ипотеке и сравните 22 ипотечные ' \
                     'программы от Сбера, ВТБ, Альфы и других банков. ' \
                     'Бесплатно, без регистрации.',
        keywords:    'ипотечный калькулятор, ипотека Рязань, рассчитать ипотеку, ' \
                     'семейная ипотека, льготная ипотека, ставка ипотеки',
        canonical:   request.url.split('?').first
      )
    end

    def calculate
      principal    = params[:principal].to_f
      annual_rate  = params[:rate].to_f / 100.0
      months       = params[:term].to_i * 12
      monthly_rate = annual_rate / 12.0
      payment =
        if monthly_rate.zero? || months.zero?
          months.zero? ? 0 : (principal / months)
        else
          principal * (monthly_rate * (1 + monthly_rate)**months) / ((1 + monthly_rate)**months - 1)
        end
      render json: {
        monthly_payment: payment.round(2),
        total: (payment * months).round(2),
        overpayment: (payment * months - principal).round(2)
      }
    end

    def banks
      render_coming_soon('Банки-партнёры')
    end

    def programs
      render_coming_soon('Программы кредитования')
    end

    private

    def safe_macro
      MacroRatesService.call || { key_rate: nil, mortgage_rate: 16.5, deposit_rate: nil, stale: true }
    rescue StandardError => e
      Rails.logger.warn("[MortgageCalculatorsController] macro fetch failed: #{e.message}")
      { key_rate: nil, mortgage_rate: 16.5, deposit_rate: nil, stale: true }
    end

    def lookup_property(slug)
      return nil if slug.blank?
      Property.friendly.find(slug)
    rescue ActiveRecord::RecordNotFound
      nil
    end

    # Query-string driven prefill. Used by:
    #   - property show CTA → ?from_property=<slug>
    #   - chat-bot tool reply links → ?price=&rate=&term_years=&down_payment_pct=
    #   - direct visits → fall back to sensible Russian-market defaults
    def build_form_state
      default_rate = @macro[:mortgage_rate] || 16.5
      price        = (params[:price].presence || @source_property&.price || 5_000_000).to_i
      dp_pct       = (params[:down_payment_pct].presence || 20).to_f
      {
        price:            price,
        down_payment:     (params[:down_payment].presence || (price * dp_pct / 100.0).round).to_i,
        down_payment_pct: dp_pct,
        term_years:       (params[:term_years].presence || 20).to_i,
        rate:             (params[:rate].presence || default_rate).to_f,
        program_id:       params[:program_id]
      }
    end

    def faq_items
      [
        {
          q: 'Какой первый взнос нужен для ипотеки?',
          a: 'Минимальный первый взнос по большинству программ — от 15-20% стоимости объекта. По семейной и IT-ипотеке — от 20%, по льготным программам Дом.РФ — от 15%. Без первого взноса купить квартиру в ипотеку нельзя.'
        },
        {
          q: 'Можно ли получить ипотеку без официального дохода?',
          a: 'Некоторые банки (например, Альфа, Т-Банк) одобряют ипотеку по «двум документам» — без справки 2-НДФЛ, но со ставкой на 1-3% выше базовой. Самозанятым нужна выписка по счёту за 6-12 месяцев.'
        },
        {
          q: 'Что такое семейная ипотека и кому она доступна?',
          a: 'Семейная ипотека под 6% годовых — государственная программа для семей с ребёнком, родившимся после 01.01.2018. Лимит кредита — до 12 млн ₽ для регионов. С 2026 года — расширена на семьи с любым ребёнком до 6 лет.'
        },
        {
          q: 'Что выгоднее — аннуитетный или дифференцированный платёж?',
          a: 'Аннуитетный — равные платежи весь срок, переплата выше. Дифференцированный — платежи уменьшаются со временем, общая переплата ниже, но первые годы платёж выше. Наш калькулятор считает аннуитет — самый распространённый формат в РФ.'
        },
        {
          q: 'За сколько одобряют ипотеку?',
          a: 'Первичное решение по заявке — 1-3 рабочих дня. Полное одобрение конкретного объекта (с оценкой и страховкой) — 5-14 дней. АН Виктори помогает с пакетом документов и сопровождает сделку до регистрации.'
        },
        {
          q: 'Можно ли использовать материнский капитал как первый взнос?',
          a: 'Да. Маткапитал (с 2026 года — 833 026 ₽ на первенца) можно использовать как первый взнос или досрочное гашение. Ребёнок должен быть прописан в купленной квартире, и потребуется выделение долей.'
        }
      ]
    end

  end
end
