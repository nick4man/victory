# repo-index.md — карта классов (auto-generated)

> Сжатый индекс: путь → классы/модули в файле. Регенерация: `rake repo:map`.

## app/models

```
app/models/activation_event.rb — class ActivationEvent
app/models/admin_user.rb — class AdminUser
app/models/application_record.rb — class ApplicationRecord
app/models/article.rb — class Article
app/models/article_embedding.rb — class ArticleEmbedding
app/models/bank_rate_snapshot.rb — class BankRateSnapshot
app/models/bot_command_log.rb — class BotCommandLog
app/models/buyer_order.rb — class BuyerOrder
app/models/case_study.rb — class CaseStudy
app/models/chat_message.rb — class ChatMessage
app/models/city_median_price.rb — class CityMedianPrice
app/models/client_document.rb — class ClientDocument
app/models/concerns/agent_profile.rb — module AgentProfile
app/models/concerns/renders_landing_blocks.rb — module RendersLandingBlocks
app/models/conversation.rb — class Conversation
app/models/crm_card.rb — class CrmCard
app/models/crm_card_transition.rb — class CrmCardTransition
app/models/crm_report.rb — class CrmReport
app/models/daily_digest.rb — class DailyDigest
app/models/department.rb — class Department
app/models/district.rb — class District
app/models/document.rb — class Document
app/models/document_requirement.rb — class DocumentRequirement
app/models/document_upload.rb — class DocumentUpload
app/models/external_listing.rb — class ExternalListing
app/models/favorite.rb — class Favorite
app/models/inquiry.rb — class Inquiry
app/models/landing_content.rb — class LandingContent
app/models/lead_event.rb — class LeadEvent
app/models/lead_event_embedding.rb — class LeadEventEmbedding
app/models/listing_consent.rb — class ListingConsent
app/models/magic_link_token.rb — class MagicLinkToken
app/models/message.rb — class Message
app/models/mls_listing.rb — class MlsListing
app/models/nextcloud/share_link.rb — module Nextcloud, class ShareLink
app/models/note.rb — class Note
app/models/notification.rb — class Notification
app/models/partner_agency.rb — class PartnerAgency
app/models/phone_stop_list.rb — class PhoneStopList
app/models/price_history.rb — class PriceHistory
app/models/property.rb — class Property
app/models/property_embedding.rb — class PropertyEmbedding
app/models/property_type.rb — class PropertyType
app/models/property_valuation.rb — class PropertyValuation
app/models/property_view.rb — class PropertyView
app/models/referral.rb — class Referral
app/models/residential_complex.rb — class ResidentialComplex
app/models/review.rb — class Review
app/models/saved_search.rb — class SavedSearch
app/models/service_order.rb — class ServiceOrder
app/models/service_type.rb — class ServiceType
app/models/show_report.rb — class ShowReport
app/models/staff_metric.rb — class StaffMetric
app/models/staff_question.rb — class StaffQuestion
app/models/task.rb — class Task
app/models/task_batch.rb — class TaskBatch
app/models/telegram_group_message.rb — class TelegramGroupMessage
app/models/telegram_group_message_embedding.rb — class TelegramGroupMessageEmbedding
app/models/telegram_user.rb — class TelegramUser
app/models/telegram_webhook_ack.rb — class TelegramWebhookAck
app/models/tg_link_token.rb — class TgLinkToken
app/models/topnlab_doc_chunk.rb — class TopnlabDocChunk
app/models/topnlab_sync_run.rb — class TopnlabSyncRun
app/models/user.rb — class User
app/models/viewing_schedule.rb — class ViewingSchedule
app/models/zhk_fact.rb — class ZhkFact
app/models/zhk_ingest_run.rb — class ZhkIngestRun
app/models/zhk_observation.rb — class ZhkObservation
app/models/zhk_price_point.rb — class ZhkPricePoint
```

## app/controllers

```
app/controllers/admin/articles_controller.rb — module Admin, class ArticlesController
app/controllers/admin/bank_rates_controller.rb — module Admin, class BankRatesController
app/controllers/admin/case_studies_controller.rb — module Admin, class CaseStudiesController
app/controllers/admin/dashboard_controller.rb — module Admin, class DashboardController
app/controllers/admin/health_controller.rb — module Admin, class HealthController
app/controllers/admin/landing_contents_controller.rb — module Admin, class LandingContentsController
app/controllers/admin/partner_agencies_controller.rb — module Admin, class PartnerAgenciesController
app/controllers/admin/properties_controller.rb — module Admin, class PropertiesController
app/controllers/admin/referrals_controller.rb — module Admin, class ReferralsController
app/controllers/admin/residential_complexes_controller.rb — module Admin, class ResidentialComplexesController
app/controllers/admin/reviews_controller.rb — module Admin, class ReviewsController
app/controllers/admin/sessions_controller.rb — module Admin, class SessionsController
app/controllers/admin/topnlab_status_controller.rb — module Admin, class TopnlabStatusController
app/controllers/admin/users_controller.rb — module Admin, class UsersController
app/controllers/admin/zhk_discrepancies_controller.rb — module Admin, class ZhkDiscrepanciesController
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
app/controllers/cabinet/auth_controller.rb — class Cabinet::AuthController
app/controllers/cabinet/consents_controller.rb — class Cabinet::ConsentsController
app/controllers/cabinet/documents_controller.rb — class Cabinet::DocumentsController
app/controllers/cabinet/favorites_controller.rb — class Cabinet::FavoritesController
app/controllers/cabinet/passwords_controller.rb — class Cabinet::PasswordsController
app/controllers/cabinet/profile_controller.rb — module Cabinet, class ProfileController
app/controllers/cabinet/properties_controller.rb — class Cabinet::PropertiesController
app/controllers/cabinet_controller.rb — class CabinetController
app/controllers/case_studies_controller.rb — class CaseStudiesController
app/controllers/chat/conversations_controller.rb — module Chat, class ConversationsController
app/controllers/chat/messages_controller.rb — module Chat, class MessagesController
app/controllers/chat/presence_controller.rb — module Chat, class PresenceController
app/controllers/chatbot/messages_controller.rb — module Chatbot, class MessagesController
app/controllers/concerns/admin/uploads_block_images.rb — module Admin, module UploadsBlockImages
app/controllers/concerns/admin_token_auth.rb — module AdminTokenAuth
app/controllers/concerns/chat/page_context_params.rb — module Chat, module PageContextParams
app/controllers/concerns/coming_soon_section.rb — module ComingSoonSection
app/controllers/concerns/renders_not_found.rb — module RendersNotFound
app/controllers/concerns/visitor_identity.rb — module VisitorIdentity
app/controllers/contact_forms_controller.rb — class ContactFormsController
app/controllers/dashboard/admin/client_documents_controller.rb — module Dashboard, module Admin, class ClientDocumentsController
app/controllers/dashboard/admin/kpi_controller.rb — module Dashboard, module Admin, class KpiController
app/controllers/dashboard/admin/properties_controller.rb — module Dashboard, module Admin, class PropertiesController
app/controllers/dashboard/admin/reports_controller.rb — module Dashboard, module Admin, class ReportsController
app/controllers/dashboard/base_controller.rb — module Dashboard, class BaseController
app/controllers/dashboard/comparisons_controller.rb — module Dashboard, class ComparisonsController
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
app/controllers/dashboard_controller.rb — class DashboardController
app/controllers/errors_controller.rb — class ErrorsController
app/controllers/external_listings_controller.rb — class ExternalListingsController
app/controllers/feeds_controller.rb — class FeedsController
app/controllers/foreign/audits_controller.rb — class Foreign::AuditsController
app/controllers/foreign_controller.rb — class ForeignController
app/controllers/forms/agent_contacts_controller.rb — module Forms, class AgentContactsController
app/controllers/forms/callback_requests_controller.rb — module Forms, class CallbackRequestsController
app/controllers/forms/consultation_requests_controller.rb — module Forms, class ConsultationRequestsController
app/controllers/forms/mortgage_requests_controller.rb — module Forms, class MortgageRequestsController
app/controllers/forms/quick_inquiries_controller.rb — module Forms, class QuickInquiriesController
app/controllers/forms/service_requests_controller.rb — module Forms, class ServiceRequestsController
app/controllers/forms/viewing_requests_controller.rb — module Forms, class ViewingRequestsController
app/controllers/health_controller.rb — class HealthController
app/controllers/home_controller.rb — class HomeController
app/controllers/index_now_key_controller.rb — class IndexNowKeyController
app/controllers/landing_controller.rb — class LandingController
app/controllers/landings_controller.rb — class LandingsController
app/controllers/news_controller.rb — class NewsController
app/controllers/pages_controller.rb — class PagesController
app/controllers/partners/auth_controller.rb — module Partners, class AuthController
app/controllers/partners/dashboard_controller.rb — module Partners, class DashboardController
app/controllers/premium_controller.rb — class PremiumController
app/controllers/properties_controller.rb — class PropertiesController
app/controllers/property_valuations_controller.rb — class PropertyValuationsController
app/controllers/public_consents_controller.rb — class PublicConsentsController
app/controllers/pwa_controller.rb — class PwaController
app/controllers/residential_complexes_controller.rb — class ResidentialComplexesController
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
app/controllers/valuations/investment_controller.rb — class Valuations::InvestmentController
app/controllers/valuations_controller.rb — class ValuationsController
app/controllers/webhooks/amocrm_controller.rb — module Webhooks, class AmocrmController
app/controllers/webhooks/news_ingest_controller.rb — module Webhooks, class NewsIngestController
app/controllers/webhooks/telegram_controller.rb — module Webhooks, class TelegramController
app/controllers/webhooks/topnlab_controller.rb — module Webhooks, class TopnlabController
app/controllers/webhooks/topnlab_reports_controller.rb — module Webhooks, class TopnlabReportsController
app/controllers/webhooks/yookassa_controller.rb — module Webhooks, class YookassaController
app/controllers/webhooks/zhk_ingest_controller.rb — module Webhooks, class ZhkIngestController
```

## app/services

```
app/services/agency_contract_pdf_service.rb — class AgencyContractPdfService
app/services/agency_metrics_service.rb — class AgencyMetricsService
app/services/articles/telegram_publisher.rb — module Articles, class TelegramPublisher
app/services/audit_engine/audit_request.rb — module AuditEngine, class AuditRequest
app/services/audit_engine/client.rb — module AuditEngine, class Client
app/services/audit_engine/error.rb — module AuditEngine, class Error
app/services/audit_engine/response_error.rb — module AuditEngine, class ResponseError
app/services/audit_engine/unavailable_error.rb — module AuditEngine, class UnavailableError
app/services/audit_pdf/bank_offers_page.rb — module AuditPdf, class BankOffersPage
app/services/audit_pdf/conversion_table_page.rb — module AuditPdf, class ConversionTablePage
app/services/audit_pdf/cover_page.rb — module AuditPdf, class CoverPage
app/services/audit_pdf/ei_details_page.rb — module AuditPdf, class EiDetailsPage
app/services/audit_pdf/glossary_page.rb — module AuditPdf, class GlossaryPage
app/services/audit_pdf/scenarios_page.rb — module AuditPdf, class ScenariosPage
app/services/audit_pdf/sensitivity_chart.rb — module AuditPdf, class SensitivityChart
app/services/audit_pdf/theme.rb — module AuditPdf, module Theme, module Helpers
app/services/audit_pdf/visa_residency_content_generator.rb — module AuditPdf, class VisaResidencyContentGenerator
app/services/audit_pdf/visa_residency_page.rb — module AuditPdf, class VisaResidencyPage
app/services/audit_pdf_generator.rb — class AuditPdfGenerator
app/services/audit_report_notifier.rb — class AuditReportNotifier
app/services/avito_feed_mapper.rb — class AvitoFeedMapper
app/services/bank_rates/banki_ru_parser.rb — module BankRates, class BankiRuParser
app/services/bulk_activation_qr_pdf_service.rb — class BulkActivationQrPdfService
app/services/cabinet/consent_requester.rb — class Cabinet::ConsentRequester, class Error
app/services/cabinet_invitation_dispatcher.rb — class CabinetInvitationDispatcher
app/services/cabinet_invitation_sms_service.rb — class CabinetInvitationSmsService
app/services/cabinet_invitation_tg_service.rb — class CabinetInvitationTgService
app/services/chat_tools/aggregate_market.rb — module ChatTools, module AggregateMarket
app/services/chat_tools/base.rb — module ChatTools, module Base
app/services/chat_tools/calculate_mortgage.rb — module ChatTools, module CalculateMortgage
app/services/chat_tools/estimate_property_valuation.rb — module ChatTools, module EstimatePropertyValuation
app/services/chat_tools/find_in_district_polygon.rb — module ChatTools, module FindInDistrictPolygon
app/services/chat_tools/format.rb — module ChatTools, module Format
app/services/chat_tools/get_landing_content.rb — module ChatTools, module GetLandingContent
app/services/chat_tools/get_property_details.rb — module ChatTools, module GetPropertyDetails
app/services/chat_tools/list_mortgage_programs.rb — module ChatTools, module ListMortgagePrograms
app/services/chat_tools/qualify_lead.rb — module ChatTools, module QualifyLead
app/services/chat_tools/registry.rb — module ChatTools, module Registry
app/services/chat_tools/run_investment_audit.rb — module ChatTools, module RunInvestmentAudit
app/services/chat_tools/search_properties.rb — module ChatTools, module SearchProperties
app/services/chat_tools/semantic_search.rb — module ChatTools, module SemanticSearch
app/services/chat_tools/staff/agent_status.rb — module ChatTools, module Staff, module AgentStatus
app/services/chat_tools/staff/director_self_audit.rb — module ChatTools, module Staff, module DirectorSelfAudit
app/services/chat_tools/staff/document_checklist_status.rb — module ChatTools, module Staff, module DocumentChecklistStatus
app/services/chat_tools/staff/kpi_for.rb — module ChatTools, module Staff, module KpiFor
app/services/chat_tools/staff/list_my_open_tasks.rb — module ChatTools, module Staff, module ListMyOpenTasks
app/services/chat_tools/staff/lookup_lead.rb — module ChatTools, module Staff, module LookupLead
app/services/chat_tools/staff/lookup_task.rb — module ChatTools, module Staff, module LookupTask
app/services/chat_tools/staff/market_comparables.rb — module ChatTools, module Staff, module MarketComparables
app/services/chat_tools/staff/nextcloud_list_templates.rb — module ChatTools, module Staff, module NextcloudListTemplates
app/services/chat_tools/staff/nextcloud_lookup_deal.rb — module ChatTools, module Staff, module NextcloudLookupDeal
app/services/chat_tools/staff/registry.rb — module ChatTools, module Staff, module Registry
app/services/chat_tools/staff/search_all_leads.rb — module ChatTools, module Staff, module SearchAllLeads
app/services/chat_tools/staff/search_all_tasks.rb — module ChatTools, module Staff, module SearchAllTasks
app/services/chat_tools/staff/search_group_messages.rb — module ChatTools, module Staff, module SearchGroupMessages
app/services/chat_tools/staff/summarize_group_messages.rb — module ChatTools, module Staff, module SummarizeGroupMessages
app/services/chat_tools/submit_review.rb — module ChatTools, module SubmitReview
app/services/chat_tools/url.rb — module ChatTools, module Url
app/services/cian_feed_mapper.rb — class CianFeedMapper
app/services/cities.rb — module Cities
app/services/crm/contact_parser.rb — module Crm, class ContactParser
app/services/crm/owner_linker.rb — module Crm, class OwnerLinker
app/services/crm/telegram_reachability.rb — module Crm, class TelegramReachability
app/services/crm_cards/checker.rb — module CrmCards, class Checker
app/services/crm_cards/field_value.rb — module CrmCards, module FieldValue
app/services/crm_cards/permissions.rb — module CrmCards, class Permissions
app/services/crm_cards/permissions_report.rb — module CrmCards, class PermissionsReport
app/services/crm_cards/phone_matches.rb — module CrmCards, module PhoneMatches
app/services/crm_cards/schema.rb — module CrmCards, module Schema
app/services/crm_reports/base.rb — module CrmReports, class Base
app/services/crm_reports/inventory_pdf.rb — module CrmReports, class InventoryPdf
app/services/crm_reports/seller_presentation.rb — module CrmReports, class SellerPresentation
app/services/currency_rates_service.rb — class CurrencyRatesService
app/services/dadata/address_suggestions.rb — module Dadata, class AddressSuggestions
app/services/deposit/programs_service.rb — module Deposit, class ProgramsService
app/services/document_checklist/auto_match_to_requirement.rb — module DocumentChecklist, class AutoMatchToRequirement
app/services/document_checklist/builder.rb — module DocumentChecklist, class Builder
app/services/document_checklist/manager.rb — module DocumentChecklist, class Manager, class ApplyError
app/services/document_checklist/reminder_sender.rb — module DocumentChecklist, class ReminderSender
app/services/document_checklist/sla_assessor.rb — module DocumentChecklist, class SlaAssessor
app/services/document_checklist/template_registry.rb — module DocumentChecklist, class TemplateRegistry
app/services/document_checklist/tokenizer.rb — module DocumentChecklist, class Tokenizer
app/services/document_intake/egrn_parser.rb — module DocumentIntake, class EgrnParser
app/services/document_intake/inn_parser.rb — module DocumentIntake, class InnParser
app/services/document_intake/nextcloud_mirror.rb — module DocumentIntake, class NextcloudMirror
app/services/document_intake/passport_parser.rb — module DocumentIntake, class PassportParser
app/services/document_intake/photo_classifier.rb — module DocumentIntake, class PhotoClassifier
app/services/embedding/article_text_template.rb — module Embedding, class ArticleTextTemplate
app/services/embedding/google_client.rb — module Embedding, class GoogleClient, class Error
app/services/embedding/lead_event_text_template.rb — module Embedding, module LeadEventTextTemplate
app/services/embedding/property_text_template.rb — module Embedding, module PropertyTextTemplate
app/services/embedding/telegram_group_message_text_template.rb — module Embedding, module TelegramGroupMessageTextTemplate
app/services/express_report_notifier.rb — class ExpressReportNotifier
app/services/external_listings/yrl_parser.rb — module ExternalListings, class YrlParser
app/services/firecrawl/client.rb — module Firecrawl, class Client, class Error
app/services/formatters/date_format.rb — module Formatters, module DateFormat
app/services/formatters/price_parse.rb — module Formatters, module PriceParse
app/services/geocoding/address_lookup.rb — module Geocoding, class AddressLookup
app/services/kpi/agency_digest.rb — module Kpi, class AgencyDigest
app/services/kpi/morning_digest.rb — module Kpi, class MorningDigest
app/services/kpi/show_funnel.rb — module Kpi, class ShowFunnel
app/services/kpi/staff_snapshot.rb — module Kpi, class StaffSnapshot
app/services/kpi/weekly_report.rb — module Kpi, class WeeklyReport
app/services/lead/intake.rb — module Lead, class Intake
app/services/lead/intake/client_resolver.rb — module Lead, class Intake, class ClientResolver
app/services/lead/intake/crm_webhook_source.rb — module Lead, class Intake, class CrmWebhookSource
app/services/lead/intake/manual_source.rb — module Lead, class Intake, class ManualSource
app/services/lead/intake/site_source.rb — module Lead, class Intake, class SiteSource
app/services/lead/intake/tg_dm_source.rb — module Lead, class Intake, class TgDmSource
app/services/lead/property_resolver.rb — module Lead, class PropertyResolver
app/services/listing_stats.rb — class ListingStats
app/services/llm/chat_responder.rb — module Llm, class ChatResponder
app/services/llm/intent_classifier.rb — module Llm, class IntentClassifier
app/services/llm/omni_client.rb — module Llm, class OmniClient, class Error
app/services/llm/page_context.rb — module Llm, module PageContext
app/services/llm/page_greeting.rb — module Llm, module PageGreeting
app/services/llm/question_classifier.rb — module Llm, class QuestionClassifier
app/services/llm/scope_guard.rb — module Llm, module ScopeGuard
app/services/llm/staff_chat_responder.rb — module Llm, class StaffChatResponder
app/services/llm/tool_runner.rb — module Llm, class ToolRunner
app/services/macro_rates_service.rb — class MacroRatesService
app/services/mls_sync/listing_mapper.rb — module MlsSync, class ListingMapper
app/services/mls_sync/topnlab_sync_service.rb — module MlsSync, class TopnlabSyncService
app/services/mortgage/programs_service.rb — module Mortgage, class ProgramsService
app/services/mortgage_application_notifier.rb — class MortgageApplicationNotifier
app/services/moscow_districts.rb — module MoscowDistricts
app/services/nextcloud/client.rb — module Nextcloud, class Client, class Error, class Forbidden, class NotFound
app/services/nextcloud/deal_folder_resolver.rb — module Nextcloud, class DealFolderResolver
app/services/nextcloud/share_link_generator.rb — module Nextcloud, class ShareLinkGenerator, class Error
app/services/nextcloud/template_catalog.rb — module Nextcloud, class TemplateCatalog
app/services/nextcloud/voice_archiver.rb — module Nextcloud, class VoiceArchiver
app/services/pdf_generator_service.rb — class PdfGeneratorService
app/services/privacy/transcript_redactor.rb — module Privacy, class TranscriptRedactor
app/services/property/commercial_type_classifier.rb — class Property, class CommercialTypeClassifier
app/services/property_avm.rb — class PropertyAvm
app/services/property_dossier/agent_page.rb — module PropertyDossier, class AgentPage
app/services/property_dossier/cover_page.rb — module PropertyDossier, class CoverPage
app/services/property_dossier/cta_page.rb — module PropertyDossier, class CtaPage
app/services/property_dossier/description_page.rb — module PropertyDossier, class DescriptionPage
app/services/property_dossier/gallery_page.rb — module PropertyDossier, class GalleryPage
app/services/property_dossier_pdf_generator.rb — class PropertyDossierPdfGenerator
app/services/property_evaluation/bootstrap_ci.rb — module PropertyEvaluation, class BootstrapCi
app/services/property_evaluation/comparable_finder.rb — module PropertyEvaluation, class ComparableFinder
app/services/property_evaluation/composite_estimator.rb — module PropertyEvaluation, class CompositeEstimator
app/services/property_evaluation/hedonic.rb — module PropertyEvaluation, class Hedonic
app/services/property_evaluation/price_estimator.rb — module PropertyEvaluation, class PriceEstimator
app/services/property_evaluation_service.rb — class PropertyEvaluationService
app/services/property_feed_mapper.rb — class PropertyFeedMapper
app/services/property_rooms_parser.rb — class PropertyRoomsParser
app/services/qr_renderer.rb — class QrRenderer
app/services/recommendation_service.rb — class RecommendationService
app/services/referrals/auto_creator.rb — module Referrals, class AutoCreator
app/services/review_moderation_notifier.rb — class ReviewModerationNotifier
app/services/ryazan_districts.rb — module RyazanDistricts
app/services/sandbox/codespace.rb — module Sandbox, class Codespace, class Error
app/services/seo/how_to_extractor.rb — module Seo, class HowToExtractor
app/services/seo/index_now_notifier.rb — module Seo, class IndexNowNotifier
app/services/seo/property_meta_generator.rb — module Seo, class PropertyMetaGenerator
app/services/sms/client.rb — module Sms, class Client
app/services/sms/sms_ru_client.rb — module Sms, class SmsRuClient, class ConfigError
app/services/sms/smsc_client.rb — module Sms, class SmscClient, class ConfigError
app/services/spb_districts.rb — module SpbDistricts
app/services/staff/resolver.rb — module Staff, class Resolver
app/services/staff_submission_detector.rb — class StaffSubmissionDetector
app/services/tavily/client.rb — module Tavily, class Client, class Error
app/services/telegram/alert_throttle.rb — module Telegram, class AlertThrottle
app/services/telegram/client.rb — module Telegram, class Client, class Error
app/services/telegram/client_bot/activation_request_processor.rb — module Telegram, module ClientBot, class ActivationRequestProcessor
app/services/telegram/client_bot/link_processor.rb — module Telegram, module ClientBot, class LinkProcessor
app/services/telegram/client_bot/photo_intake_processor.rb — module Telegram, module ClientBot, class PhotoIntakeProcessor
app/services/telegram/client_bot/text_intake_processor.rb — module Telegram, module ClientBot, class TextIntakeProcessor
app/services/telegram/critical_recipients.rb — module Telegram, class CriticalRecipients
app/services/telegram/escalation_notifier.rb — module Telegram, class EscalationNotifier
app/services/telegram/inbound_processor.rb — module Telegram, class InboundProcessor
app/services/telegram/inbox_saver.rb — module Telegram, class InboxSaver
app/services/telegram/push_to_client.rb — module Telegram, class PushToClient
app/services/telegram/reaction_handler.rb — module Telegram, class ReactionHandler
app/services/telegram/topic_registry.rb — module Telegram, class TopicRegistry
app/services/telegram/work_bot/anchor_migrator.rb — module Telegram, module WorkBot, class AnchorMigrator
app/services/telegram/work_bot/anomaly_detector.rb — module Telegram, module WorkBot, class AnomalyDetector
app/services/telegram/work_bot/anomaly_detector_job.rb — module Telegram, module WorkBot, class AnomalyDetectorJob
app/services/telegram/work_bot/anomaly_notifier.rb — module Telegram, module WorkBot, class AnomalyNotifier
app/services/telegram/work_bot/auto_discovery.rb — module Telegram, module WorkBot, class AutoDiscovery
app/services/telegram/work_bot/callbacks/assign_callback.rb — module Telegram, module WorkBot, module Callbacks, class AssignCallback
app/services/telegram/work_bot/callbacks/assign_cancel_callback.rb — module Telegram, module WorkBot, module Callbacks, class AssignCancelCallback
app/services/telegram/work_bot/callbacks/assign_to_callback.rb — module Telegram, module WorkBot, module Callbacks, class AssignToCallback
app/services/telegram/work_bot/callbacks/base.rb — module Telegram, module WorkBot, module Callbacks, class Base
app/services/telegram/work_bot/callbacks/dashboard_drill_callback.rb — module Telegram, module WorkBot, module Callbacks, class DashboardDrillCallback
app/services/telegram/work_bot/callbacks/link_staff_callback.rb — module Telegram, module WorkBot, module Callbacks, class LinkStaffCallback
app/services/telegram/work_bot/callbacks/owner_request_callback.rb — module Telegram, module WorkBot, module Callbacks, class OwnerRequestCallback
app/services/telegram/work_bot/callbacks/photo_disposition_callback.rb — module Telegram, module WorkBot, module Callbacks, class PhotoDispositionCallback
app/services/telegram/work_bot/callbacks/route_callback.rb — module Telegram, module WorkBot, module Callbacks, class RouteCallback
app/services/telegram/work_bot/callbacks/segment_callback.rb — module Telegram, module WorkBot, module Callbacks, class SegmentCallback
app/services/telegram/work_bot/callbacks/show_assign_callback.rb — module Telegram, module WorkBot, module Callbacks, class ShowAssignCallback
app/services/telegram/work_bot/callbacks/show_report_callback.rb — module Telegram, module WorkBot, module Callbacks, class ShowReportCallback
app/services/telegram/work_bot/callbacks/spam_callback.rb — module Telegram, module WorkBot, module Callbacks, class SpamCallback
app/services/telegram/work_bot/callbacks/stage_callback.rb — module Telegram, module WorkBot, module Callbacks, class StageCallback
app/services/telegram/work_bot/callbacks/task_action_callback.rb — module Telegram, module WorkBot, module Callbacks, class TaskActionCallback
app/services/telegram/work_bot/callbacks/task_batch_confirm_callback.rb — module Telegram, module WorkBot, module Callbacks, class TaskBatchConfirmCallback
app/services/telegram/work_bot/callbacks/tutorial_callback.rb — module Telegram, module WorkBot, module Callbacks, class TutorialCallback
app/services/telegram/work_bot/callbacks/wip_stub.rb — module Telegram, module WorkBot, module Callbacks, class WipStub
app/services/telegram/work_bot/callbacks/wizard_callback.rb — module Telegram, module WorkBot, module Callbacks, class WizardCallback
app/services/telegram/work_bot/callbacks_router.rb — module Telegram, module WorkBot, class CallbacksRouter
app/services/telegram/work_bot/cheatsheet_renderer.rb — module Telegram, module WorkBot, class CheatsheetRenderer
app/services/telegram/work_bot/commands/assign.rb — module Telegram, module WorkBot, module Commands, class Assign
app/services/telegram/work_bot/commands/bargain.rb — module Telegram, module WorkBot, module Commands, class Bargain
app/services/telegram/work_bot/commands/base.rb — module Telegram, module WorkBot, module Commands, class Base
app/services/telegram/work_bot/commands/cancel.rb — module Telegram, module WorkBot, module Commands, class Cancel
app/services/telegram/work_bot/commands/cheatsheet.rb — module Telegram, module WorkBot, module Commands, class Cheatsheet
app/services/telegram/work_bot/commands/close.rb — module Telegram, module WorkBot, module Commands, class Close
app/services/telegram/work_bot/commands/dashboard.rb — module Telegram, module WorkBot, module Commands, class Dashboard
app/services/telegram/work_bot/commands/deactivate.rb — module Telegram, module WorkBot, module Commands, class Deactivate
app/services/telegram/work_bot/commands/demote.rb — module Telegram, module WorkBot, module Commands, class Demote
app/services/telegram/work_bot/commands/doc.rb — module Telegram, module WorkBot, module Commands, class Doc
app/services/telegram/work_bot/commands/done.rb — module Telegram, module WorkBot, module Commands, class Done
app/services/telegram/work_bot/commands/help.rb — module Telegram, module WorkBot, module Commands, class Help
app/services/telegram/work_bot/commands/lead.rb — module Telegram, module WorkBot, module Commands, class Lead
app/services/telegram/work_bot/commands/link.rb — module Telegram, module WorkBot, module Commands, class Link
app/services/telegram/work_bot/commands/menu.rb — module Telegram, module WorkBot, module Commands, class Menu
app/services/telegram/work_bot/commands/note.rb — module Telegram, module WorkBot, module Commands, class Note
app/services/telegram/work_bot/commands/objections.rb — module Telegram, module WorkBot, module Commands, class Objections
app/services/telegram/work_bot/commands/promote.rb — module Telegram, module WorkBot, module Commands, class Promote
app/services/telegram/work_bot/commands/reassign.rb — module Telegram, module WorkBot, module Commands, class Reassign
app/services/telegram/work_bot/commands/reopen.rb — module Telegram, module WorkBot, module Commands, class Reopen
app/services/telegram/work_bot/commands/resume_batch.rb — module Telegram, module WorkBot, module Commands, class ResumeBatch
app/services/telegram/work_bot/commands/route.rb — module Telegram, module WorkBot, module Commands, class Route
app/services/telegram/work_bot/commands/segment.rb — module Telegram, module WorkBot, module Commands, class Segment
app/services/telegram/work_bot/commands/show.rb — module Telegram, module WorkBot, module Commands, class Show
app/services/telegram/work_bot/commands/stage.rb — module Telegram, module WorkBot, module Commands, class Stage
app/services/telegram/work_bot/commands/start_test.rb — module Telegram, module WorkBot, module Commands, class StartTest
app/services/telegram/work_bot/commands/task.rb — module Telegram, module WorkBot, module Commands, class Task
app/services/telegram/work_bot/commands/tutorial.rb — module Telegram, module WorkBot, module Commands, class Tutorial
app/services/telegram/work_bot/commands/unstage.rb — module Telegram, module WorkBot, module Commands, class Unstage
app/services/telegram/work_bot/commands/whoami.rb — module Telegram, module WorkBot, module Commands, class Whoami
app/services/telegram/work_bot/commands/whoami_force.rb — module Telegram, module WorkBot, module Commands, class WhoamiForce
app/services/telegram/work_bot/commands_menu_sync.rb — module Telegram, module WorkBot, class CommandsMenuSync
app/services/telegram/work_bot/daily_digest_job.rb — module Telegram, module WorkBot, class DailyDigestJob
app/services/telegram/work_bot/deal_mirror.rb — module Telegram, module WorkBot, class DealMirror
app/services/telegram/work_bot/director_dashboard.rb — module Telegram, module WorkBot, class DirectorDashboard
app/services/telegram/work_bot/dispatcher_digest.rb — module Telegram, module WorkBot, class DispatcherDigest, class Error
app/services/telegram/work_bot/dm_qna_handler.rb — module Telegram, module WorkBot, class DmQnaHandler
app/services/telegram/work_bot/hashtag_handler.rb — module Telegram, module WorkBot, class HashtagHandler
app/services/telegram/work_bot/lead_announcer.rb — module Telegram, module WorkBot, class LeadAnnouncer
app/services/telegram/work_bot/lead_assignment.rb — module Telegram, module WorkBot, class LeadAssignment
app/services/telegram/work_bot/lead_closure.rb — module Telegram, module WorkBot, class LeadClosure
app/services/telegram/work_bot/lead_stage_transition.rb — module Telegram, module WorkBot, class LeadStageTransition
app/services/telegram/work_bot/lead_task_creator.rb — module Telegram, module WorkBot, class LeadTaskCreator
app/services/telegram/work_bot/owner_intake_processor.rb — module Telegram, module WorkBot, class OwnerIntakeProcessor
app/services/telegram/work_bot/photo_intake_processor.rb — module Telegram, module WorkBot, class PhotoIntakeProcessor
app/services/telegram/work_bot/photo_share_continuation.rb — module Telegram, module WorkBot, class PhotoShareContinuation
app/services/telegram/work_bot/photo_task_continuation.rb — module Telegram, module WorkBot, class PhotoTaskContinuation
app/services/telegram/work_bot/qna_handler.rb — module Telegram, module WorkBot, class QnaHandler
app/services/telegram/work_bot/quiet_hours.rb — module Telegram, module WorkBot, class QuietHours
app/services/telegram/work_bot/router.rb — module Telegram, module WorkBot, class Router
app/services/telegram/work_bot/segment_keyboard.rb — module Telegram, module WorkBot, class SegmentKeyboard
app/services/telegram/work_bot/show_reports/confirmer.rb — module Telegram, module WorkBot, module ShowReports, class Confirmer
app/services/telegram/work_bot/show_reports/extractor.rb — module Telegram, module WorkBot, module ShowReports, class Extractor
app/services/telegram/work_bot/show_reports/finalizer.rb — module Telegram, module WorkBot, module ShowReports, class Finalizer
app/services/telegram/work_bot/show_reports/intake.rb — module Telegram, module WorkBot, module ShowReports, class Intake
app/services/telegram/work_bot/show_routing.rb — module Telegram, module WorkBot, class ShowRouting
app/services/telegram/work_bot/sla/ping_service.rb — module Telegram, module WorkBot, module Sla, class PingService
app/services/telegram/work_bot/task_batch_confirmer.rb — module Telegram, module WorkBot, class TaskBatchConfirmer, class Error
app/services/telegram/work_bot/task_dispatcher.rb — module Telegram, module WorkBot, class TaskDispatcher
app/services/telegram/work_bot/task_extractor.rb — module Telegram, module WorkBot, class TaskExtractor, class Error
app/services/telegram/work_bot/task_reopen.rb — module Telegram, module WorkBot, class TaskReopen
app/services/telegram/work_bot/topic_discovery.rb — module Telegram, module WorkBot, class TopicDiscovery
app/services/telegram/work_bot/tutorial_lessons.rb — module Telegram, module WorkBot, module TutorialLessons
app/services/telegram/work_bot/tutorial_renderer.rb — module Telegram, module WorkBot, class TutorialRenderer
app/services/telegram/work_bot/voice_intake_processor.rb — module Telegram, module WorkBot, class VoiceIntakeProcessor
app/services/telegram/work_bot/voice_intent_branch.rb — module Telegram, module WorkBot, class VoiceIntentBranch
app/services/telegram/work_bot/voice_transcriber.rb — module Telegram, module WorkBot, class VoiceTranscriber, class Error, class MissingKeyError, class DownloadError, class GroqError
app/services/telegram/work_bot/weekly_summary_job.rb — module Telegram, module WorkBot, class WeeklySummaryJob
app/services/telegram/work_bot/wizard/close_flow.rb — module Telegram, module WorkBot, module Wizard, class CloseFlow
app/services/telegram/work_bot/wizard/engine.rb — module Telegram, module WorkBot, module Wizard, class Engine
app/services/telegram/work_bot/wizard/flow.rb — module Telegram, module WorkBot, module Wizard, class Flow
app/services/telegram/work_bot/wizard/lead_picking.rb — module Telegram, module WorkBot, module Wizard, module LeadPicking
app/services/telegram/work_bot/wizard/menu.rb — module Telegram, module WorkBot, module Wizard, module Menu
app/services/telegram/work_bot/wizard/reopen_flow.rb — module Telegram, module WorkBot, module Wizard, class ReopenFlow
app/services/telegram/work_bot/wizard/task_flow.rb — module Telegram, module WorkBot, module Wizard, class TaskFlow
app/services/topnlab/activity_log_fetcher.rb — module Topnlab, class ActivityLogFetcher
app/services/topnlab/client.rb — module Topnlab, class Client, class Error
app/services/topnlab/importer.rb — module Topnlab, class Importer
app/services/topnlab/notes_sync_service.rb — module Topnlab, class NotesSyncService
app/services/topnlab/order_mapper.rb — module Topnlab, class OrderMapper
app/services/topnlab/orders_importer.rb — module Topnlab, class OrdersImporter
app/services/topnlab/owner_sync_service.rb — module Topnlab, class OwnerSyncService
app/services/topnlab/property_mapper.rb — module Topnlab, class PropertyMapper
app/services/topnlab/staff_sync_service.rb — module Topnlab, class StaffSyncService
app/services/topnlab/stages_cache.rb — module Topnlab, class StagesCache
app/services/topnlab/stats_client.rb — module Topnlab, class StatsClient
app/services/topnlab_docs/indexer.rb — module TopnlabDocs, class Indexer
app/services/topnlab_docs/searcher.rb — module TopnlabDocs, class Searcher
app/services/valuations/ai_comp_filter.rb — module Valuations, class AiCompFilter
app/services/valuations/ai_explainer.rb — module Valuations, class AiExplainer
app/services/valuations/ai_synthetic_comps.rb — module Valuations, class AiSyntheticComps
app/services/valuations/cross_city_adapter.rb — module Valuations, class CrossCityAdapter
app/services/valuations/semantic_comp_finder.rb — module Valuations, class SemanticCompFinder
app/services/valuations/sitemap_comp_finder.rb — module Valuations, class SitemapCompFinder
app/services/valuations/websearch_comp_finder.rb — module Valuations, class WebsearchCompFinder
app/services/yandex/webmaster_opportunities_service.rb — module Yandex, class WebmasterOpportunitiesService, class ConfigError
app/services/yandex/webmaster_query_history_service.rb — module Yandex, class WebmasterQueryHistoryService, class ConfigError
app/services/yandex/webmaster_recrawl_service.rb — module Yandex, class WebmasterRecrawlService, class ConfigError, class QuotaExceeded
app/services/yandex/webmaster_summary_service.rb — module Yandex, class WebmasterSummaryService, class ConfigError
app/services/yandex_vision/client.rb — module YandexVision, class Client, class Error
app/services/zhk/attachment_suggester.rb — module Zhk, class AttachmentSuggester
app/services/zhk/catalog_hints.rb — module Zhk, module CatalogHints
app/services/zhk/coverage.rb — module Zhk, module Coverage
app/services/zhk/discrepancies.rb — module Zhk, module Discrepancies
app/services/zhk/fact_applier.rb — module Zhk, module FactApplier
app/services/zhk/ingest.rb — module Zhk, class Ingest, class DuplicateRace, class InvalidComplex
app/services/zhk/matcher.rb — module Zhk, module Matcher
app/services/zhk/run_summary.rb — module Zhk, module RunSummary
```

## app/jobs

```
app/jobs/application_job.rb — class ApplicationJob
app/jobs/bank_rates_refresh_job.rb — class BankRatesRefreshJob
app/jobs/digest_cleanup_job.rb — class DigestCleanupJob
app/jobs/dispatcher_digest_refresh_job.rb — class DispatcherDigestRefreshJob
app/jobs/document_intake/parser_job.rb — module DocumentIntake, class ParserJob
app/jobs/document_reminder_job.rb — class DocumentReminderJob
app/jobs/embed_article_job.rb — class EmbedArticleJob
app/jobs/embed_lead_event_job.rb — class EmbedLeadEventJob
app/jobs/embed_property_job.rb — class EmbedPropertyJob
app/jobs/embed_telegram_group_message_job.rb — class EmbedTelegramGroupMessageJob
app/jobs/external_listings/yrl_sync_job.rb — module ExternalListings, class YrlSyncJob
app/jobs/inquiry_notification_job.rb — class InquiryNotificationJob
app/jobs/investment_audit_job.rb — class InvestmentAuditJob
app/jobs/kpi/agency_digest_job.rb — module Kpi, class AgencyDigestJob
app/jobs/kpi/morning_digest_job.rb — module Kpi, class MorningDigestJob
app/jobs/kpi/staff_snapshot_job.rb — module Kpi, class StaffSnapshotJob
app/jobs/kpi/weekly_report_job.rb — module Kpi, class WeeklyReportJob
app/jobs/llm_reply_job.rb — class LlmReplyJob
app/jobs/mls_sync_job.rb — class MlsSyncJob
app/jobs/nextcloud/voice_archive_cleanup_job.rb — module Nextcloud, class VoiceArchiveCleanupJob
app/jobs/owner_request_job.rb — class OwnerRequestJob
app/jobs/property/classify_commercial_type_job.rb — class Property, class ClassifyCommercialTypeJob
app/jobs/property_district_backfill_job.rb — class PropertyDistrictBackfillJob
app/jobs/property_valuation_completed_job.rb — class PropertyValuationCompletedJob
app/jobs/property_valuation_follow_up_job.rb — class PropertyValuationFollowUpJob
app/jobs/property_valuation_job.rb — class PropertyValuationJob
app/jobs/refresh_topnlab_stats_job.rb — class RefreshTopnlabStatsJob
app/jobs/sandbox/codespace_ready_job.rb — module Sandbox, class CodespaceReadyJob
app/jobs/send_viewing_reminders_job.rb — class SendViewingRemindersJob
app/jobs/seo/generate_property_meta_job.rb — module Seo, class GeneratePropertyMetaJob
app/jobs/seo/index_now_notify_job.rb — module Seo, class IndexNowNotifyJob
app/jobs/task_batch_expiry_job.rb — class TaskBatchExpiryJob
app/jobs/telegram/inbound_processor_job.rb — module Telegram, class InboundProcessorJob
app/jobs/telegram/webhook_acks_cleanup_job.rb — module Telegram, class WebhookAcksCleanupJob
app/jobs/telegram/work_bot/polling_job.rb — module Telegram, module WorkBot, class PollingJob
app/jobs/telegram/work_bot/sla/ping_job.rb — module Telegram, module WorkBot, module Sla, class PingJob
app/jobs/telegram/work_bot/sla/task_ping_job.rb — module Telegram, module WorkBot, module Sla, class TaskPingJob
app/jobs/telegram/work_bot/sla/tasks_watchdog_job.rb — module Telegram, module WorkBot, module Sla, class TasksWatchdogJob
app/jobs/telegram/work_bot/sla/watchdog_job.rb — module Telegram, module WorkBot, module Sla, class WatchdogJob
app/jobs/telegram_inbox_save_job.rb — class TelegramInboxSaveJob
app/jobs/telegram_notify_job.rb — class TelegramNotifyJob
app/jobs/topnlab_crm_intake_job.rb — class TopnlabCrmIntakeJob
app/jobs/topnlab_note_push_job.rb — class TopnlabNotePushJob
app/jobs/topnlab_orders_sync_job.rb — class TopnlabOrdersSyncJob
app/jobs/topnlab_owner_sync_job.rb — class TopnlabOwnerSyncJob
app/jobs/topnlab_photo_sync_job.rb — class TopnlabPhotoSyncJob
app/jobs/topnlab_property_import_job.rb — class TopnlabPropertyImportJob
app/jobs/topnlab_staff_sync_job.rb — class TopnlabStaffSyncJob
app/jobs/topnlab_sync_job.rb — class TopnlabSyncJob
app/jobs/topnlab_webhook_health_job.rb — class TopnlabWebhookHealthJob
app/jobs/update_property_statistics_job.rb — class UpdatePropertyStatisticsJob
app/jobs/viewing_notification_job.rb — class ViewingNotificationJob
app/jobs/yandex/recrawl_url_job.rb — module Yandex, class RecrawlUrlJob
```

## app/mailers

```
app/mailers/application_mailer.rb — class ApplicationMailer
app/mailers/cabinet_invitation_mailer.rb — class CabinetInvitationMailer
app/mailers/cabinet_mailer.rb — class CabinetMailer
app/mailers/inquiry_mailer.rb — class InquiryMailer
app/mailers/listing_consent_mailer.rb — class ListingConsentMailer
app/mailers/partner_invitation_mailer.rb — class PartnerInvitationMailer
app/mailers/property_valuation_mailer.rb — class PropertyValuationMailer
app/mailers/telegram_auth_mailer.rb — class TelegramAuthMailer
app/mailers/user_mailer.rb — class UserMailer
app/mailers/viewing_mailer.rb — class ViewingMailer
```

## app/channels

```
app/channels/application_cable/channel.rb — module ApplicationCable, class Channel
app/channels/application_cable/connection.rb — module ApplicationCable, class Connection
app/channels/cabinet_channel.rb — class CabinetChannel
app/channels/chat_channel.rb — class ChatChannel
app/channels/conversation_channel.rb — class ConversationChannel
app/channels/valuation_channel.rb — class ValuationChannel
```

## lib

```
```
