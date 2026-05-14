# frozen_string_literal: true

# /cases — public landing для анонимизированных кейсов по закрытым
# сделкам. Pillar 2 strategic vector активирован. Контент драфтится
# case-study-writer agent'ом, публикуется через /admin/case_studies.
class CaseStudiesController < ApplicationController
  def index
    @case_studies = CaseStudy.public_facing
    # reorder(nil) — снять scope recent перед DISTINCT, иначе Postgres
    # ругается «for SELECT DISTINCT, ORDER BY expressions must appear in select list».
    @districts    = CaseStudy.published_only.reorder(nil).distinct.pluck(:district).compact.sort

    set_meta_tags(
      title:       'Кейсы — закрытые сделки АН «Виктори»',
      description: 'Реальные истории клиентов: подбор, переговоры, ипотека, ' \
                   "закрытие сделки. С #{AgencyInfo::FOUNDING_DATE} года " \
                   "в Рязани и области.",
      keywords:    'кейсы недвижимости, закрытые сделки, риелтор Рязань, отзывы',
      canonical:   request.url.split('?').first
    )
  end

  def show
    @case_study = CaseStudy.public_facing.friendly.find(params[:slug])
    CaseStudy.increment_counter(:views_count, @case_study.id)

    set_meta_tags(
      title:       @case_study.meta_title.presence || @case_study.title,
      description: @case_study.meta_description.presence || @case_study.excerpt.presence ||
                   'Анонимизированный кейс по закрытой сделке — АН «Виктори».',
      canonical:   request.url.split('?').first
    )
  rescue ActiveRecord::RecordNotFound
    redirect_to cases_path, alert: 'Кейс не найден или скрыт.'
  end
end
