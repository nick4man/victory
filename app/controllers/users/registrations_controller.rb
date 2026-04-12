# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [:create]
  before_action :configure_account_update_params, only: [:update]

  # GET /users/sign_up
  # def new
  #   super
  # end

  # POST /users
  # def create
  #   super
  # end

  # GET /users/edit
  # def edit
  #   super
  # end

  # PUT /users
  # def update
  #   super
  # end

  # DELETE /users
  # def destroy
  #   super
  # end

  # GET /users/cancel
  # Forces the session data which is usually expired after sign
  # in to be expired now. This is useful if the user wants to
  # cancel their account setup.
  # def cancel
  #   super
  # end

  protected

  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up, keys: [:first_name, :last_name, :phone])
  end

  def configure_account_update_params
    devise_parameter_sanitizer.permit(:account_update, keys: [:first_name, :last_name, :phone, :bio])
  end

  def after_sign_up_path_for(resource)
    dashboard_root_path
  end

  def after_update_path_for(resource)
    dashboard_root_path
  end
end
