# frozen_string_literal: true

module Api
  module V1
    class ProfilesController < BaseController
      def show
        render_success(serialize_user(current_api_user))
      end

      def update
        if current_api_user.update(profile_params)
          render_updated(serialize_user(current_api_user))
        else
          render_error('Validation failed', errors: current_api_user.errors.full_messages)
        end
      end

      private

      def profile_params
        params.require(:profile).permit(:first_name, :last_name, :phone, :bio, :company, :position)
      end

      def serialize_user(u)
        {
          id: u.id,
          email: u.email,
          first_name: u.first_name,
          last_name: u.last_name,
          phone: u.phone,
          role: u.role,
          avatar_url: u.avatar_path,
          favorites_count: u.favorites_count,
          inquiries_count: u.inquiries_count
        }
      end
    end
  end
end
