# frozen_string_literal: true

# Phase 16.6 — semantic embedding для LeadEvent.
# Pattern from PropertyEmbedding + TelegramGroupMessageEmbedding.
#
# Use cases:
#   • SearchAllLeads mode='semantic' — концепт-поиск
#     («лиды с задержкой подписания», «недовольные клиенты»)
#   • Lead duplicate detection — найти семантически близкие лиды
#     (один клиент по разным каналам)
#   • «Лиды похожие на закрытый-выигранный №87» — finding similar opportunities
#
# Re-embed trigger: LeadEvent.metadata changes (summary/name/notes append).
# В жизненном цикле лида metadata часто mutate'ится — для каждого update
# enqueue job, но SHA256-based skip-if-unchanged cheap'тoff redundant calls.
class LeadEventEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :lead_event
end
