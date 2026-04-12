# frozen_string_literal: true

class PropertyPolicy < ApplicationPolicy
  def index?
    true
  end

  def show?
    record.active? || owned_by_user? || user&.admin?
  end

  def create?
    user.present?
  end

  def new?
    create?
  end

  def update?
    owned_by_user? || user&.admin?
  end

  def edit?
    update?
  end

  def destroy?
    owned_by_user? || user&.admin?
  end

  def publish?
    (owned_by_user? && user&.agent?) || user&.admin?
  end

  def unpublish?
    publish?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user&.agent?
        scope.published.or(scope.where(user: user))
      else
        scope.published
      end
    end
  end

  private

  def owned_by_user?
    user.present? && record.user_id == user.id
  end
end
