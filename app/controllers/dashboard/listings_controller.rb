# frozen_string_literal: true

module Dashboard
  # Client-side "Мои объекты" tab. Brings together every piece of property
  # data the logged-in user has touched:
  #   1. PropertyValuation — online valuations / express estimates / audits
  #      they've ordered (linked via user_id at submit OR backfilled by email
  #      in User#link_existing_records when they register).
  #   2. Property where owner_user_id = user — listings the user is selling
  #      through АН (populated once we wire the seller-flow form). For now
  #      the section renders empty for most clients.
  class ListingsController < BaseController
    def index
      @valuations = PropertyValuation
                      .where(user_id: current_user.id)
                      .order(created_at: :desc)
                      .limit(50)
      @selling_properties = Property.unscoped
                                    .where(owner_user_id: current_user.id, deleted_at: nil)
                                    .includes(:property_type, :user)
                                    .order(created_at: :desc)
                                    .limit(50)
    end
  end
end
