# frozen_string_literal: true

class ViewingsController < ApplicationController
  before_action :authenticate_user!

  def index
    @viewings = current_user.viewing_schedules.order(preferred_date: :desc)
  end
end
