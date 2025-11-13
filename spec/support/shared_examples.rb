# frozen_string_literal: true

# Shared Examples for RSpec

# Authentication shared examples
RSpec.shared_examples 'requires authentication' do
  it 'returns unauthorized when not authenticated' do
    perform_request
    expect(response).to have_http_status(:unauthorized)
  end
end

RSpec.shared_examples 'requires authorization' do
  it 'returns forbidden when not authorized' do
    perform_request
    expect(response).to have_http_status(:forbidden)
  end
end

# API response shared examples
RSpec.shared_examples 'returns success' do
  it 'returns 200 status' do
    perform_request
    expect(response).to have_http_status(:success)
  end

  it 'returns valid JSON' do
    perform_request
    expect { JSON.parse(response.body) }.not_to raise_error
  end
end

RSpec.shared_examples 'returns paginated results' do
  it 'includes pagination metadata' do
    perform_request
    json = JSON.parse(response.body)
    expect(json).to have_key('data')
    expect(json).to have_key('meta')
    expect(json['meta']).to have_key('total')
    expect(json['meta']).to have_key('page')
    expect(json['meta']).to have_key('per_page')
  end
end

# Model validation shared examples
RSpec.shared_examples 'validates presence of' do |attribute|
  it "validates presence of #{attribute}" do
    subject.send("#{attribute}=", nil)
    expect(subject).not_to be_valid
    expect(subject.errors[attribute]).to include("can't be blank")
  end
end

RSpec.shared_examples 'validates uniqueness of' do |attribute|
  it "validates uniqueness of #{attribute}" do
    existing = create(described_class.name.underscore.to_sym)
    subject.send("#{attribute}=", existing.send(attribute))
    expect(subject).not_to be_valid
    expect(subject.errors[attribute]).to include('has already been taken')
  end
end

# Soft delete shared examples
RSpec.shared_examples 'soft deletable' do
  describe '#destroy' do
    it 'soft deletes the record' do
      subject.save!
      expect { subject.destroy }.not_to change(described_class, :count)
      expect(subject.reload.deleted_at).not_to be_nil
    end
  end

  describe '.active' do
    it 'returns only non-deleted records' do
      active = create(described_class.name.underscore.to_sym)
      deleted = create(described_class.name.underscore.to_sym)
      deleted.destroy

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(deleted)
    end
  end
end

