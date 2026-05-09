# frozen_string_literal: true

# Custom report registered in Topnlab CRM via Reports API.
# When agent in Topnlab triggers the report on selected cards, Topnlab POSTs
# {user, ids, report_id} to our Webhooks::TopnlabReportsController which
# instantiates `template_class` and returns a PDF download URL.
class CrmReport < ApplicationRecord
  TEMPLATE_CLASSES = %w[CrmReports::InventoryPdf CrmReports::SellerPresentation].freeze

  validates :title, :slug, :page_id, :template_class, presence: true
  validates :slug, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :template_class, inclusion: { in: TEMPLATE_CLASSES }

  scope :active, -> { where(active: true) }
  scope :synced, -> { where.not(crm_id: nil) }

  # Public callback URL Topnlab will hit when agent generates this report.
  def callback_url
    host = ENV['APP_HOST'].presence || 'localhost:3000'
    proto = ENV['APP_PROTOCOL'].presence || (host.include?('localhost') ? 'http' : 'https')
    "#{proto}://#{host}/webhooks/topnlab/reports/#{slug}"
  end

  # Topnlab page_id справочник (from /menu/get-all-pages).
  PAGES = {
    1 => 'Объекты компании - Аренда',
    2 => 'Объекты компании - Продажа',
    3 => 'Объекты МЛС - Аренда',
    4 => 'Объекты МЛС - Продажа',
    5 => 'Объекты Парсер - Аренда',
    6 => 'Объекты Парсер - Продажа',
    7 => 'Заявки - Аренда',
    8 => 'Заявки - Продажа',
    1011 => 'Ипотечные заявки',
    1012 => 'HR'
  }.freeze

  def page_title
    PAGES[page_id] || "Страница ##{page_id}"
  end
end
