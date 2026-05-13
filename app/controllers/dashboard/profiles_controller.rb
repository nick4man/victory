# frozen_string_literal: true

module Dashboard
  # Lets the signed-in user view and edit their own profile data: full name,
  # phone, avatar. Email/password changes route to Devise (`/users/edit`)
  # because they have stricter flows (re-confirmation, reset-password emails)
  # that we don't want to duplicate here.
  class ProfilesController < BaseController
    before_action :load_user

    def show; end

    def edit; end

    def update
      if @user.update(profile_params)
        redirect_to dashboard_profile_path, notice: 'Профиль обновлён.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def load_user
      @user = current_user
    end

    def profile_params
      params.require(:user).permit(:first_name, :last_name, :middle_name, :phone, :avatar)
    end
  end
end
