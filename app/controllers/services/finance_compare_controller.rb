# frozen_string_literal: true

module Services
  # «Вклад vs Ипотека» — отдельная страница с большим интерактивным
  # блоком сравнения. Выделена из главной страницы калькулятора, чтобы
  # каждый пункт хедера-меню «Финансы» вёл на свой URL и свою «полную»
  # компоновку, а не сжатую секцию.
  class FinanceCompareController < ApplicationController
    def show
      @macro            = safe_macro
      @deposit_programs = Deposit::ProgramsService.all

      set_meta_tags(
        title:       'Вклад или ипотека: что выгоднее? — Калькулятор АН Виктори',
        description: 'Что выгоднее: купить квартиру в ипотеку или положить на ' \
                     'депозит и снимать жильё? Сравнение двух сценариев на ' \
                     '20 лет с учётом роста цен на недвижимость и аренды.',
        keywords:    'вклад или ипотека, что выгоднее, депозит vs ипотека, аренда vs покупка',
        canonical:   request.url.split('?').first
      )
    end

    private

    def safe_macro
      MacroRatesService.call
    rescue StandardError => e
      Rails.logger.warn("[FinanceCompare#show] macro fetch failed: #{e.class}: #{e.message}")
      { key_rate: 16.0, deposit_rate: 15.0, mortgage_rate: 22.0, source: 'fallback (ЦБ РФ)' }
    end
  end
end
