# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AvitoMessage, type: :model do
  subject { build(:avito_message) }

  it { is_expected.to belong_to(:property).optional }
  it { is_expected.to validate_presence_of(:message_id) }
  it { is_expected.to validate_uniqueness_of(:message_id) }
  it { is_expected.to validate_presence_of(:chat_id) }
  it { is_expected.to validate_presence_of(:author_id) }
  it { is_expected.to validate_presence_of(:user_id) }
  it { is_expected.to validate_presence_of(:content_type) }
  it { is_expected.to validate_presence_of(:payload) }
  it { is_expected.to validate_presence_of(:direction) }

  it { is_expected.to define_enum_for(:direction).with_values(incoming: 'incoming', outgoing: 'outgoing').backed_by_column_of_type(:string).with_prefix }
end
