# frozen_string_literal: true

# Журнал решений по карточке CRM: кто, когда, из какого статуса в какой и с
# каким комментарием. Только добавление: запись не правится и не удаляется,
# поэтому soft-delete ей не нужен — удалённая запись и есть потерянный ответ
# на «почему вернули на доработку».
class CrmCardTransition < ApplicationRecord
  belongs_to :crm_card, inverse_of: :transitions
  belongs_to :actor, class_name: 'TelegramUser', optional: true # nil — система (джоб выгрузки)

  validates :from_status, :to_status, presence: true
end
