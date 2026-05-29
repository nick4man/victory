# frozen_string_literal: true

# Public agent profile pages at /agents/:slug.
# Each active agent gets a unique URL with Schema.org Person + AggregateRating
# (when approved reviews exist), enabling E-E-A-T-style rich snippets in
# Yandex/Google SERP for queries like "имя фамилия Рязань риелтор".
#
# Visibility rules (in `agent_query`):
#   - role = agent
#   - active = true and not soft-deleted
#   - agent_slug present (skipped only for system accounts that lack a name)
class AgentsController < ApplicationController
  def show
    @agent = agent_query.find_by(agent_slug: params[:slug])
    unless @agent
      # Различаем «exists в DB, но снят с публики» (410 — Я. de-index
      # быстро, особенно важно для 152-ФЗ removal requests) и
      # «slug никогда не существовал» (404 — typo / never indexed).
      return render_410 if User.unscoped.where(agent_slug: params[:slug]).exists?
      return render_404
    end

    # Property listings this agent owns / is responsible for in CRM.
    @active_properties = @agent.properties
                               .in_advertising
                               .order(created_at: :desc)
                               .limit(12) rescue Property.none

    @reviews = @agent.received_reviews.recent.limit(8)

    @meta_title       = "#{@agent.display_name} — агент по недвижимости в Рязани, АН «Виктори»"
    @meta_description = build_meta_description

    add_breadcrumb 'Команда', team_path
    add_breadcrumb @agent.display_name
  end

  private

  # Single source of truth (AgentProfile concern's `publicly_listable_agents`
  # scope) — same filter used by SitemapController so /sitemap.xml and
  # /agents/:slug agree on which agents are public.
  def agent_query
    User.publicly_listable_agents
  end

  def build_meta_description
    parts = [@agent.display_name]
    parts << (@agent.try(:crm_role_name).presence || 'агент по недвижимости')
    parts << 'АН «Виктори», Рязань'
    parts << "опыт работы: #{@agent.deals_closed_count} сделок" if @agent.deals_closed_count.to_i.positive?
    parts.join(' · ')
  end

end
