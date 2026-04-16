# frozen_string_literal: true

class Api::V1::ProfilesController < Api::V1::BaseController
  before_action :authenticate_api_user!

  def show
    render_success(current_api_user.slice(:id, :email, :first_name, :last_name, :phone))
  end

  def update
    if current_api_user.update(profile_params)
      render_success(current_api_user.slice(:id, :email, :first_name, :last_name, :phone))
    else
      render_error(current_api_user.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end

  private

  def profile_params
    params.require(:user).permit(:first_name, :last_name, :phone)
  end
end
