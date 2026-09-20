# frozen_string_literal: true

# Заявка на правку поля уже опубликованной карточки.
#
# До публикации поля правятся обычным путём (автор в черновике, модератор на
# модерации). После — карточка это запись в боевой CRM, и правка проходит
# модерацию: заявку заводит тот, кто ведёт клиента, решение принимает модератор.
class CrmCardChangeRequest < ApplicationRecord
  belongs_to :crm_card
  belongs_to :author, class_name: 'TelegramUser'
  belongs_to :reviewer, class_name: 'TelegramUser', optional: true

  enum :status, {
    pending: 'pending',   # ждёт модератора
    approved: 'approved', # поле изменено
    rejected: 'rejected'  # отклонена с объяснением
  }, prefix: true

  validates :field, presence: true

  scope :recent, -> { order(created_at: :desc) }
end
