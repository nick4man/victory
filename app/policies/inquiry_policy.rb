# frozen_string_literal: true

class InquiryPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    owner_or_property_owner? || user&.admin?
  end

  def create?
    true
  end

  def new?
    create?
  end

  def update?
    user&.admin? || (user&.agent? && property_owner?)
  end

  def destroy?
    owner? || user&.admin?
  end

  def cancel?
    owner? || user&.admin?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user&.agent?
        scope.where(property: user.properties).or(scope.where(user: user))
      else
        scope.where(user: user)
      end
    end
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end

  def property_owner?
    user.present? && record.property&.user_id == user.id
  end

  def owner_or_property_owner?
    owner? || property_owner?
  end
end
