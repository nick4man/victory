# frozen_string_literal: true

module Admin
  # Landing page for /admin — small index with counts and quick links
  # into Articles / Reviews moderation. Token-protected via AdminTokenAuth.
  class DashboardController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      @article_counts = {
        total:     Article.count,
        published: Article.published.count,
        hidden:    Article.where.not(hidden_at: nil).count,
        drafts:    Article.where(published_at: nil).count
      }
      @review_counts = {
        total:    Review.count,
        pending:  Review.where(status: Review.statuses[:pending]).count,
        approved: Review.where(status: Review.statuses[:approved]).count
      }
      # Mirror'ит keys из Admin::PropertiesController#index — те же scopes.
      base_props = Property.unscoped.where.not(external_id: nil)
      @property_counts = {
        all:              base_props.count,
        published:        base_props.where(status: :active).where.not(published_at: nil).count,
        archived:         base_props.where(status: :archived).count,
        force:            base_props.where(force_publish: true).count,
        pending_consent:  base_props.where(status: :pending_consent).count
      }
      @case_study_counts = {
        total:     CaseStudy.count,
        published: CaseStudy.where(status: CaseStudy.statuses[:published]).count,
        drafts:    CaseStudy.where(status: CaseStudy.statuses[:draft]).count
      }
      @landing_counts = {
        total:     LandingContent.count,
        published: LandingContent.published.count
      }
    end
  end
end
