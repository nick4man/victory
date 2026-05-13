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
    end
  end
end
