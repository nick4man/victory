# frozen_string_literal: true

class Dashboard::ProfilesController < Dashboard::BaseController
  def show
  end

  def edit
  end

  def update
    if current_user.update(profile_params)
      redirect_to dashboard_profile_path, notice: 'Профиль успешно обновлён'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def profile_params
    params.require(:user).permit(:first_name, :last_name, :phone, :bio, :avatar)
  end
end
