# frozen_string_literal: true

class UserPolicy < ApplicationPolicy
  def show?
    own_record? || user&.admin?
  end

  def update?
    own_record? || user&.admin?
  end

  def edit?
    update?
  end

  def destroy?
    user&.admin? && !own_record?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      user&.admin? ? scope.all : scope.where(id: user&.id)
    end
  end

  private

  def own_record?
    user.present? && record.id == user.id
  end
end
