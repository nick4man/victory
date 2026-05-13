# repo-index.md — карта классов (auto-generated, ~5k токенов)

> Сжатый индекс: путь → классы/модули в файле. Регенерация: `rake repo:index`.


## app/models

```
app/models/admin_user.rb — class AdminUser
app/models/application_record.rb — class ApplicationRecord
app/models/article_embedding.rb — class ArticleEmbedding
app/models/article.rb — class Article
app/models/bank_rate_snapshot.rb — class BankRateSnapshot
app/models/buyer_order.rb — class BuyerOrder
app/models/chat_message.rb — class ChatMessage
app/models/city_median_price.rb — class CityMedianPrice
app/models/concerns/agent_profile.rb — module AgentProfile
app/models/conversation.rb — class Conversation
app/models/crm_report.rb — class CrmReport
app/models/department.rb — class Department
app/models/district.rb — class District
app/models/document.rb — class Document
app/models/external_listing.rb — class ExternalListing
app/models/favorite.rb — class Favorite
app/models/inquiry.rb — class Inquiry
app/models/landing_content.rb — class LandingContent
app/models/lead_event.rb — class LeadEvent
app/models/message.rb — class Message
app/models/mls_listing.rb — class MlsListing
app/models/note.rb — class Note
app/models/notification.rb — class Notification
app/models/price_history.rb — class PriceHistory
app/models/property_embedding.rb — class PropertyEmbedding
app/models/property.rb — class Property
app/models/property_type.rb — class PropertyType
app/models/property_valuation.rb — class PropertyValuation
app/models/property_view.rb — class PropertyView
app/models/review.rb — class Review
app/models/saved_search.rb — class SavedSearch
app/models/service_order.rb — class ServiceOrder
app/models/service_type.rb — class ServiceType
app/models/telegram_user.rb — class TelegramUser
app/models/topnlab_sync_run.rb — class TopnlabSyncRun
app/models/user.rb — class User
app/models/viewing_schedule.rb — class ViewingSchedule
```

## app/controllers

```
app/controllers/admin/articles_controller.rb — module Admin, class ArticlesController
app/controllers/admin/bank_rates_controller.rb — module Admin, class BankRatesController
app/controllers/admin/dashboard_controller.rb — module Admin, class DashboardController
app/controllers/admin/landing_contents_controller.rb — module Admin, class LandingContentsController
app/controllers/admin/properties_controller.rb — module Admin, class PropertiesController
app/controllers/admin/reviews_controller.rb — module Admin, class ReviewsController
app/controllers/admin/sessions_controller.rb — module Admin, class SessionsController
app/controllers/admin/topnlab_status_controller.rb — module Admin, class TopnlabStatusController
app/controllers/agents_controller.rb — class AgentsController
app/controllers/api/v1/addresses_controller.rb — module Api, module V1, class AddressesController
app/controllers/api/v1/authentication_controller.rb — module Api, module V1, class AuthenticationController
app/controllers/api/v1/base_controller.rb — module Api, module V1, class BaseController
app/controllers/api/v1/favorites_controller.rb — module Api, module V1, class FavoritesController
app/controllers/api/v1/inquiries_controller.rb — module Api, module V1, class InquiriesController
app/controllers/api/v1/mortgage_calculators_controller.rb — module Api, module V1, class MortgageCalculatorsController
app/controllers/api/v1/profiles_controller.rb — module Api, module V1, class ProfilesController
app/controllers/api/v1/properties_controller.rb — module Api, module V1, class PropertiesController
app/controllers/api/v1/property_evaluations_controller.rb — module Api, module V1, class PropertyEvaluationsController
app/controllers/api/v1/recommendations_controller.rb — module Api, module V1, class RecommendationsController
app/controllers/api/v1/saved_searches_controller.rb — module Api, module V1, class SavedSearchesController
app/controllers/api/v1/stats_controller.rb — module Api, module V1, class StatsController
app/controllers/application_controller.rb — class ApplicationController
app/controllers/blog_controller.rb — class BlogController
app/controllers/chatbot/messages_controller.rb — module Chatbot, class MessagesController
app/controllers/chat/conversations_controller.rb — module Chat, class ConversationsController
app/controllers/chat/messages_controller.rb — module Chat, class MessagesController
app/controllers/chat/presence_controller.rb — module Chat, class PresenceController
app/controllers/concerns/admin_token_auth.rb — module AdminTokenAuth
app/controllers/concerns/coming_soon_section.rb — module ComingSoonSection
app/controllers/concerns/visitor_identity.rb — module VisitorIdentity
app/controllers/contact_forms_controller.rb — class ContactFormsController
app/controllers/dashboard/admin/properties_controller.rb — module Dashboard, module Admin, class PropertiesController
app/controllers/dashboard/admin/reports_controller.rb — module Dashboard, module Admin, class ReportsController
app/controllers/dashboard/base_controller.rb — module Dashboard, class BaseController
app/controllers/dashboard/comparisons_controller.rb — module Dashboard, class ComparisonsController
app/controllers/dashboard_controller.rb — class DashboardController
app/controllers/dashboard/favorites_controller.rb — module Dashboard, class FavoritesController
app/controllers/dashboard/histories_controller.rb — module Dashboard, class HistoriesController
app/controllers/dashboard/home_controller.rb — module Dashboard, class HomeController
app/controllers/dashboard/inquiries_controller.rb — module Dashboard, class InquiriesController
app/controllers/dashboard/listings_controller.rb — module Dashboard, class ListingsController
app/controllers/dashboard/messages_controller.rb — module Dashboard, class MessagesController
app/controllers/dashboard/notes_controller.rb — module Dashboard, class NotesController
app/controllers/dashboard/notifications_controller.rb — module Dashboard, class NotificationsController
app/controllers/dashboard/orders_controller.rb — module Dashboard, class OrdersController
app/controllers/dashboard/profiles_controller.rb — module Dashboard, class ProfilesController
app/controllers/dashboard/properties_controller.rb — module Dashboard, class PropertiesController
app/controllers/dashboard/saved_searches_controller.rb — module Dashboard, class SavedSearchesController
app/controllers/dashboard/settings_controller.rb — module Dashboard, class SettingsController
app/controllers/dashboard/staff_controller.rb — module Dashboard, class StaffController
app/controllers/errors_controller.rb — class ErrorsController
app/controllers/feeds_controller.rb — class FeedsController
app/controllers/forms/agent_contacts_controller.rb — module Forms, class AgentContactsController
app/controllers/forms/callback_requests_controller.rb — module Forms, class CallbackRequestsController
app/controllers/forms/consultation_requests_controller.rb — module Forms, class ConsultationRequestsController
app/controllers/forms/mortgage_requests_controller.rb — module Forms, class MortgageRequestsController
app/controllers/forms/quick_inquiries_controller.rb — module Forms, class QuickInquiriesController
app/controllers/forms/service_requests_controller.rb — module Forms, class ServiceRequestsController
app/controllers/forms/viewing_requests_controller.rb — module Forms, class ViewingRequestsController
app/controllers/health_controller.rb — class HealthController
app/controllers/home_controller.rb — class HomeController
app/controllers/landing_controller.rb — class LandingController
app/controllers/landings_controller.rb — class LandingsController
app/controllers/news_controller.rb — class NewsController
app/controllers/pages_controller.rb — class PagesController
app/controllers/properties_controller.rb — class PropertiesController
app/controllers/property_valuations_controller.rb — class PropertyValuationsController
app/controllers/pwa_controller.rb — class PwaController
app/controllers/reviews_controller.rb — class ReviewsController
app/controllers/robots_controller.rb — class RobotsController
app/controllers/sell/evaluations_controller.rb — module Sell, class EvaluationsController
app/controllers/sell/listings_controller.rb — module Sell, class ListingsController
app/controllers/sell/plans_controller.rb — module Sell, class PlansController
app/controllers/services/deposit_calculators_controller.rb — module Services, class DepositCalculatorsController
app/controllers/services/document_services_controller.rb — module Services, class DocumentServicesController
app/controllers/services/finance_compare_controller.rb — module Services, class FinanceCompareController
app/controllers/services/legal_services_controller.rb — module Services, class LegalServicesController
app/controllers/services/mortgage_applications_controller.rb — module Services, class MortgageApplicationsController
app/controllers/services/mortgage_calculators_controller.rb — module Services, class MortgageCalculatorsController
app/controllers/services/virtual_tours_controller.rb — module Services, class VirtualToursController
app/controllers/sitemap_controller.rb — class SitemapController
app/controllers/valuations_controller.rb — class ValuationsController
app/controllers/valuations/investment_controller.rb — class Valuations::InvestmentController
app/controllers/webhooks/amocrm_controller.rb — module Webhooks, class AmocrmController
app/controllers/webhooks/news_ingest_controller.rb — module Webhooks, class NewsIngestController
app/controllers/webhooks/telegram_controller.rb — module Webhooks, class TelegramController
app/controllers/webhooks/topnlab_controller.rb — module Webhooks, class TopnlabController
app/controllers/webhooks/topnlab_reports_controller.rb — module Webhooks, class TopnlabReportsController
app/controllers/webhooks/yookassa_controller.rb — module Webhooks, class YookassaController
```

## app/services

```
app/services/agency_metrics_service.rb — class AgencyMetricsService
app/services/articles/telegram_publisher.rb — module Articles, class TelegramPublisher
app/services/audit_engine/audit_request.rb — module AuditEngine, class AuditRequest
app/services/audit_engine/client.rb — module AuditEngine, class Client
app/services/audit_engine/error.rb — module AuditEngine, class Error
app/services/audit_engine/response_error.rb — module AuditEngine, class ResponseError
app/services/audit_engine/unavailable_error.rb — module AuditEngine, class UnavailableError
app/services/audit_pdf/bank_offers_page.rb — module AuditPdf, class BankOffersPage
app/services/audit_pdf/cover_page.rb — module AuditPdf, class CoverPage
app/services/audit_pdf/ei_details_page.rb — module AuditPdf, class EiDetailsPage
app/services/audit_pdf_generator.rb — class AuditPdfGenerator
app/services/audit_pdf/glossary_page.rb — module AuditPdf, class GlossaryPage
app/services/audit_pdf/scenarios_page.rb — module AuditPdf, class ScenariosPage
app/services/audit_pdf/sensitivity_chart.rb — module AuditPdf, class SensitivityChart
app/services/audit_pdf/theme.rb — module AuditPdf, module Theme, module Helpers
app/services/audit_report_notifier.rb — class AuditReportNotifier
app/services/avito_feed_mapper.rb — class AvitoFeedMapper
app/services/bank_rates/banki_ru_parser.rb — module BankRates, class BankiRuParser
app/services/chat_tools/aggregate_market.rb — module ChatTools, module AggregateMarket
app/services/chat_tools/base.rb — module ChatTools, module Base
app/services/chat_tools/calculate_mortgage.rb — module ChatTools, module CalculateMortgage
app/services/chat_tools/estimate_property_valuation.rb — module ChatTools, module EstimatePropertyValuation
app/services/chat_tools/find_in_district_polygon.rb — module ChatTools, module FindInDistrictPolygon
app/services/chat_tools/format.rb — module ChatTools, module Format
app/services/chat_tools/get_landing_content.rb — module ChatTools, module GetLandingContent
app/services/chat_tools/get_property_details.rb — module ChatTools, module GetPropertyDetails
app/services/chat_tools/registry.rb — module ChatTools, module Registry
app/services/chat_tools/run_investment_audit.rb — module ChatTools, module RunInvestmentAudit
app/services/chat_tools/search_properties.rb — module ChatTools, module SearchProperties
app/services/chat_tools/semantic_search.rb — module ChatTools, module SemanticSearch
app/services/chat_tools/submit_review.rb — module ChatTools, module SubmitReview
app/services/chat_tools/url.rb — module ChatTools, module Url
app/services/cian_feed_mapper.rb — class CianFeedMapper
app/services/crm_reports/base.rb — module CrmReports, class Base
app/services/crm_reports/inventory_pdf.rb — module CrmReports, class InventoryPdf
app/services/crm_reports/seller_presentation.rb — module CrmReports, class SellerPresentation
app/services/dadata/address_suggestions.rb — module Dadata, class AddressSuggestions
app/services/deposit/programs_service.rb — module Deposit, class ProgramsService
app/services/embedding/article_text_template.rb — module Embedding, class ArticleTextTemplate
app/services/embedding/google_client.rb — module Embedding, class GoogleClient, class Error
app/services/embedding/property_text_template.rb — module Embedding, module PropertyTextTemplate
app/services/express_report_notifier.rb — class ExpressReportNotifier
app/services/external_listings/yrl_parser.rb — module ExternalListings, class YrlParser
app/services/formatters/date_format.rb — module Formatters, module DateFormat
app/services/geocoding/address_lookup.rb — module Geocoding, class AddressLookup
app/services/lead/intake/crm_webhook_source.rb — module Lead, class Intake, class CrmWebhookSource
app/services/lead/intake/manual_source.rb — module Lead, class Intake, class ManualSource
app/services/lead/intake.rb — module Lead, class Intake
app/services/lead/intake/site_source.rb — module Lead, class Intake, class SiteSource
app/services/lead/intake/tg_dm_source.rb — module Lead, class Intake, class TgDmSource
app/services/llm/chat_responder.rb — module Llm, class ChatResponder
app/services/llm/omni_client.rb — module Llm, class OmniClient, class Error
app/services/llm/page_context.rb — module Llm, module PageContext
app/services/llm/page_greeting.rb — module Llm, module PageGreeting
app/services/llm/scope_guard.rb — module Llm, module ScopeGuard
app/services/llm/tool_runner.rb — module Llm, class ToolRunner
app/services/macro_rates_service.rb — class MacroRatesService
app/services/mls_sync/listing_mapper.rb — module MlsSync, class ListingMapper
app/services/mls_sync/topnlab_sync_service.rb — module MlsSync, class TopnlabSyncService
app/services/mortgage_application_notifier.rb — class MortgageApplicationNotifier
app/services/mortgage/programs_service.rb — module Mortgage, class ProgramsService
app/services/pdf_generator_service.rb — class PdfGeneratorService
app/services/property_avm.rb — class PropertyAvm
app/services/property_evaluation/bootstrap_ci.rb — module PropertyEvaluation, class BootstrapCi
app/services/property_evaluation/comparable_finder.rb — module PropertyEvaluation, class ComparableFinder
app/services/property_evaluation/composite_estimator.rb — module PropertyEvaluation, class CompositeEstimator
app/services/property_evaluation/hedonic.rb — module PropertyEvaluation, class Hedonic
app/services/property_evaluation/price_estimator.rb — module PropertyEvaluation, class PriceEstimator
app/services/property_evaluation_service.rb — class PropertyEvaluationService
app/services/property_feed_mapper.rb — class PropertyFeedMapper
app/services/qr_renderer.rb — class QrRenderer
app/services/recommendation_service.rb — class RecommendationService
app/services/review_moderation_notifier.rb — class ReviewModerationNotifier
app/services/ryazan_districts.rb — module RyazanDistricts
app/services/telegram/client.rb — module Telegram, class Client, class Error
app/services/telegram/escalation_notifier.rb — module Telegram, class EscalationNotifier
app/services/telegram/inbound_processor.rb — module Telegram, class InboundProcessor
app/services/telegram/inbox_saver.rb — module Telegram, class InboxSaver
app/services/telegram/topic_registry.rb — module Telegram, class TopicRegistry
app/services/telegram/work_bot/commands/base.rb — module Telegram, module WorkBot, module Commands, class Base
app/services/telegram/work_bot/commands/whoami.rb — module Telegram, module WorkBot, module Commands, class Whoami
app/services/telegram/work_bot/lead_announcer.rb — module Telegram, module WorkBot, class LeadAnnouncer
app/services/telegram/work_bot/router.rb — module Telegram, module WorkBot, class Router
app/services/telegram/work_bot/topic_discovery.rb — module Telegram, module WorkBot, class TopicDiscovery
app/services/topnlab/activity_log_fetcher.rb — module Topnlab, class ActivityLogFetcher
app/services/topnlab/client.rb — module Topnlab, class Client, class Error
app/services/topnlab/importer.rb — module Topnlab, class Importer
app/services/topnlab/notes_sync_service.rb — module Topnlab, class NotesSyncService
app/services/topnlab/order_mapper.rb — module Topnlab, class OrderMapper
app/services/topnlab/orders_importer.rb — module Topnlab, class OrdersImporter
app/services/topnlab/property_mapper.rb — module Topnlab, class PropertyMapper
app/services/topnlab/staff_sync_service.rb — module Topnlab, class StaffSyncService
app/services/topnlab/stats_client.rb — module Topnlab, class StatsClient
app/services/valuations/ai_comp_filter.rb — module Valuations, class AiCompFilter
app/services/valuations/ai_explainer.rb — module Valuations, class AiExplainer
app/services/valuations/ai_synthetic_comps.rb — module Valuations, class AiSyntheticComps
app/services/valuations/cross_city_adapter.rb — module Valuations, class CrossCityAdapter
app/services/valuations/semantic_comp_finder.rb — module Valuations, class SemanticCompFinder
```

## app/jobs

```
app/jobs/application_job.rb — class ApplicationJob
app/jobs/bank_rates_refresh_job.rb — class BankRatesRefreshJob
app/jobs/embed_article_job.rb — class EmbedArticleJob
app/jobs/embed_property_job.rb — class EmbedPropertyJob
app/jobs/external_listings/yrl_sync_job.rb — module ExternalListings, class YrlSyncJob
app/jobs/inquiry_notification_job.rb — class InquiryNotificationJob
app/jobs/investment_audit_job.rb — class InvestmentAuditJob
app/jobs/llm_reply_job.rb — class LlmReplyJob
app/jobs/mls_sync_job.rb — class MlsSyncJob
app/jobs/property_district_backfill_job.rb — class PropertyDistrictBackfillJob
app/jobs/property_valuation_completed_job.rb — class PropertyValuationCompletedJob
app/jobs/property_valuation_follow_up_job.rb — class PropertyValuationFollowUpJob
app/jobs/refresh_topnlab_stats_job.rb — class RefreshTopnlabStatsJob
app/jobs/send_viewing_reminders_job.rb — class SendViewingRemindersJob
app/jobs/telegram_inbox_save_job.rb — class TelegramInboxSaveJob
app/jobs/telegram_notify_job.rb — class TelegramNotifyJob
app/jobs/topnlab_note_push_job.rb — class TopnlabNotePushJob
app/jobs/topnlab_orders_sync_job.rb — class TopnlabOrdersSyncJob
app/jobs/topnlab_photo_sync_job.rb — class TopnlabPhotoSyncJob
app/jobs/topnlab_property_import_job.rb — class TopnlabPropertyImportJob
app/jobs/topnlab_staff_sync_job.rb — class TopnlabStaffSyncJob
app/jobs/topnlab_sync_job.rb — class TopnlabSyncJob
app/jobs/update_property_statistics_job.rb — class UpdatePropertyStatisticsJob
app/jobs/viewing_notification_job.rb — class ViewingNotificationJob
```

## app/mailers

```
app/mailers/application_mailer.rb — class ApplicationMailer
app/mailers/inquiry_mailer.rb — class InquiryMailer
app/mailers/property_valuation_mailer.rb — class PropertyValuationMailer
app/mailers/telegram_auth_mailer.rb — class TelegramAuthMailer
app/mailers/user_mailer.rb — class UserMailer
app/mailers/viewing_mailer.rb — class ViewingMailer
```

## app/channels

```
app/channels/application_cable/channel.rb — module ApplicationCable, class Channel
app/channels/application_cable/connection.rb — module ApplicationCable, class Connection
app/channels/chat_channel.rb — class ChatChannel
app/channels/conversation_channel.rb — class ConversationChannel
app/channels/valuation_channel.rb — class ValuationChannel
```

## lib

```
```
