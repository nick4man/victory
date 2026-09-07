# frozen_string_literal: true

module Admin
  # Поля, по которым источники службы сбора данных о ЖК противоречат друг
  # другу. Экран только показывает: правку вносит редактор в карточке ЖК,
  # потому что решение «кто прав» человеческое, а не автоматическое —
  # разрешение конфликта («принять это значение») сюда намеренно не входит.
  class ZhkDiscrepanciesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      # `Zhk::Discrepancies.all` уже делает `includes(:residential_complex)`
      # внутри группировки — во вьюхе по `@rows` дополнительных запросов на
      # связь быть не должно.
      @rows = Zhk::Discrepancies.all
    end
  end
end
