# frozen_string_literal: true

# Translation maps for the investment-audit + express-valuation surfaces.
# Audit-engine returns verdicts/strategies/confidence as English codes
# (BUY/WAIT, mortgage/cash, high/medium); we render them in Russian
# everywhere except in JSON payloads and analytics events.
module ValuationsHelper
  VERDICT_RU = {
    'BUY'     => 'ПОКУПАТЬ',
    'WAIT'    => 'ПОДОЖДАТЬ',
    'NEUTRAL' => 'НЕЙТРАЛЬНО',
    'HOLD'    => 'УДЕРЖИВАТЬ',
    'SELL'    => 'ПРОДАВАТЬ',
    'REJECT'  => 'ОТКЛОНИТЬ'
  }.freeze

  STRATEGY_RU = {
    'cash'     => 'Наличными',
    'mortgage' => 'Ипотека',
    'deposit'  => 'Депозит-альтернатива',
    'hybrid'   => 'Комбинированная'
  }.freeze

  CONFIDENCE_RU = {
    'high'   => 'Высокая уверенность',
    'medium' => 'Средняя уверенность',
    'low'    => 'Низкая уверенность'
  }.freeze

  # Short labels for compact UI elements (badges, table headers) where
  # the full phrase would overflow. Used by PDF cover-page and result-card.
  VERDICT_SHORT_RU = {
    'BUY'     => 'ПОКУПАТЬ',
    'WAIT'    => 'ПОДОЖДАТЬ',
    'NEUTRAL' => 'НЕЙТРАЛЬНО',
    'HOLD'    => 'УДЕРЖИВАТЬ',
    'SELL'    => 'ПРОДАВАТЬ'
  }.freeze

  # Per-verdict explanation shown under the headline label. Returns nil
  # for unknown verdicts so the view can omit the line silently.
  VERDICT_EXPLAIN = {
    'BUY'     => 'Сделка экономически выгодна — индекс эффективности и сценарии подтверждают доходность.',
    'WAIT'    => 'Сделку лучше отложить — либо переоценена, либо риски выше доходности.',
    'NEUTRAL' => 'Сделка нейтральная — на текущих параметрах ни выгодно, ни убыточно.',
    'HOLD'    => 'Стоит удерживать существующий объект, не продавать сейчас.',
    'SELL'    => 'Стоит продать — рыночная цена выше расчётной справедливой.'
  }.freeze

  def verdict_ru(value)
    VERDICT_RU[value.to_s.upcase] || value.to_s
  end

  def verdict_short_ru(value)
    VERDICT_SHORT_RU[value.to_s.upcase] || verdict_ru(value)
  end

  def verdict_explanation(value)
    VERDICT_EXPLAIN[value.to_s.upcase]
  end

  def strategy_ru(value)
    STRATEGY_RU[value.to_s.downcase] || value.to_s
  end

  def confidence_ru(value)
    CONFIDENCE_RU[value.to_s.downcase] || value.to_s
  end
end
