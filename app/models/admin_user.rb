# frozen_string_literal: true

# AdminUser model for ActiveAdmin
class AdminUser < ActiveRecord::Base
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable,
         :recoverable,
         :rememberable,
         :validatable

  # Associations
  # Add any associations here if needed

  # Validations
  validates :email, presence: true, uniqueness: true

  # Scopes
  scope :active, -> { where(deleted_at: nil) }

  # Methods
  def active_for_authentication?
    super && deleted_at.nil?
  end

  def inactive_message
    deleted_at.present? ? :deleted : super
  end
end

