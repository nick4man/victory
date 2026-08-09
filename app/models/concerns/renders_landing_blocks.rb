# frozen_string_literal: true

# Пре-рендер типизированных блоков контента в две проекции:
#   body_html  — для публичной страницы
#   body_plain — для контекста чат-бота (ChatTools::GetLandingContent)
#
# Обе проекции считаются из одного и того же массива блоков, поэтому
# разъехаться не могут. Извлечено из LandingContent (08.08.26), когда
# второй потребитель — ResidentialComplex — получил такое же поле
# `body_blocks`.
#
# Требования к включающей модели: колонки `body_blocks` (jsonb),
# `body_html` (text), `body_plain` (text). Словарь видов блоков —
# LandingContent::BLOCK_KINDS, рендерер — LandingBlocksHelper.
module RendersLandingBlocks
  extend ActiveSupport::Concern

  included do
    before_save :rerender_caches, if: -> { body_blocks_changed? }
  end

  private

  def rerender_caches
    helper = ActionController::Base.helpers
    # Mix in our helper so we have access to render_landing_blocks /
    # landing_blocks_to_plain. ActionController::Base.helpers carries
    # only built-in tag helpers by default.
    helper.extend(LandingBlocksHelper)

    self.body_html  = helper.render_landing_blocks(body_blocks).to_s
    self.body_plain = helper.landing_blocks_to_plain(body_blocks).to_s
  end
end
