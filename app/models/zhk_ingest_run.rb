# frozen_string_literal: true

# Один прогон одного источника: сколько наблюдений он отправил (после
# вычитания `:invalid`) в этот заход `run.py`. Append-only журнал,
# soft-delete не применяется — как и `ZhkObservation`, это не доменная
# сущность, а история для сравнения прогон к прогону в `Zhk::RunSummary`.
class ZhkIngestRun < ApplicationRecord
  validates :source, :ran_at, presence: true
  validates :count, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :for_source, ->(source) { where(source: source) }
end
