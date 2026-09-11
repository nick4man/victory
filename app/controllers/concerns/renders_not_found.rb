# frozen_string_literal: true

# Общий soft-404 guard для контроллеров программных SEO-страниц. Извлечено
# из `LandingsController` при добавлении `ResidentialComplexesController`
# (третий потребитель — оправдывает вынос).
#
# `render`, а НЕ `raise ActionController::RoutingError` — тот превращается
# в дефолтный `ApplicationController#render_404`, а `ActiveRecord::RecordNotFound`
# в дефолтный `#record_not_found` вовсе редиректит на root (см.
# `application_controller.rb`). Оба варианта хуже: программные страницы должны
# отдавать настоящий HTTP 404 с обычным шаблоном ошибки на неизвестный slug,
# без редиректов и без soft-200 — Yandex тяжело штрафует soft-404.
module RendersNotFound
  extend ActiveSupport::Concern

  private

  def render_not_found(reason = nil)
    tag = self.class.name.delete_suffix('Controller')
    Rails.logger.info("[#{tag}] 404: #{reason}") if reason
    render template: 'errors/not_found', status: :not_found, formats: [:html]
  end
end
