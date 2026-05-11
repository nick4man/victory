# frozen_string_literal: true

# Landing controller for /valuations — presents two distinct modes:
#
#   1. Express ("сколько стоит мой объект?") → PropertyValuationsController
#   2. Investment Audit ("стоит ли покупать?") → Valuations::InvestmentController
#
# Both modes share the same PropertyValuation model (discriminated by
# `audit_mode`). This controller is a thin index — no form here.
class ValuationsController < ApplicationController
  def index; end
end
