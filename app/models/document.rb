# frozen_string_literal: true

# == Schema Information
#
# Table name: documents
#
#  id              :bigint           not null, primary key
#  property_id     :bigint           not null
#  user_id         :bigint
#  title           :string           not null
#  description     :text
#  document_type   :string           not null
#  file_url        :string           not null
#  file_name       :string
#  content_type    :string
#  file_size       :bigint
#  public          :boolean          default(FALSE), not null
#  downloads_count :integer          default(0), not null
#  verified_at     :datetime
#  verified_by_id  :bigint
#  status          :string           default("pending"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  deleted_at      :datetime
#

class Document < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :property
  belongs_to :user, optional: true # uploader
  belongs_to :verified_by, class_name: 'User', optional: true
  
  # ============================================
  # ENUMS
  # ============================================
  
  enum document_type: {
    contract: 'contract',
    certificate: 'certificate',
    ownership: 'ownership',
    floor_plan: 'floor_plan',
    technical_passport: 'technical_passport',
    appraisal_report: 'appraisal_report',
    inspection_report: 'inspection_report',
    other: 'other'
  }, _prefix: true
  
  enum status: {
    pending: 'pending',
    approved: 'approved',
    rejected: 'rejected'
  }, _prefix: true
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :title, presence: true, length: { maximum: 255 }
  validates :document_type, presence: true
  validates :file_url, presence: true
  validates :status, presence: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  scope :public_documents, -> { where(public: true) }
  scope :private_documents, -> { where(public: false) }
  scope :verified, -> { where.not(verified_at: nil) }
  scope :unverified, -> { where(verified_at: nil) }
  scope :by_type, ->(type) { where(document_type: type) }
  scope :by_status, ->(status) { where(status: status) }
  scope :recent, -> { order(created_at: :desc) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  before_save :calculate_file_size, if: :file_url_changed?
  after_destroy :soft_delete
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Soft delete
  def soft_delete
    update_column(:deleted_at, Time.current) unless deleted_at.present?
  end
  
  # Check if document is deleted
  def deleted?
    deleted_at.present?
  end
  
  # Restore soft-deleted document
  def restore
    update_column(:deleted_at, nil)
  end
  
  # Verify document
  def verify!(user)
    update(verified_at: Time.current, verified_by: user, status: 'approved')
  end
  
  # Reject document
  def reject!(user, reason = nil)
    update(status: 'rejected', verified_by: user)
  end
  
  # Check if verified
  def verified?
    verified_at.present?
  end
  
  # Increment download counter
  def increment_downloads!
    increment!(:downloads_count)
  end
  
  # File size in human readable format
  def file_size_humanized
    return 'N/A' unless file_size.present?
    
    number = file_size.to_f
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    
    return "#{number} B" if number < 1024
    
    units.each_with_index do |unit, index|
      return "#{(number / (1024 ** index)).round(2)} #{unit}" if number < (1024 ** (index + 1))
    end
    
    "#{(number / (1024 ** (units.length - 1))).round(2)} #{units.last}"
  end
  
  # Document type humanized
  def document_type_humanized
    I18n.t("activerecord.attributes.document.document_types.#{document_type}", default: document_type.humanize)
  end
  
  # Status humanized
  def status_humanized
    I18n.t("activerecord.attributes.document.statuses.#{status}", default: status.humanize)
  end
  
  # File extension
  def file_extension
    return '' unless file_name.present?
    File.extname(file_name).delete('.')
  end
  
  # Check if image
  def image?
    ['image/jpeg', 'image/png', 'image/gif', 'image/webp'].include?(content_type)
  end
  
  # Check if PDF
  def pdf?
    content_type == 'application/pdf'
  end
  
  private
  
  def calculate_file_size
    # This would be implemented based on your file storage solution
    # For now, it's a placeholder
  end
end

