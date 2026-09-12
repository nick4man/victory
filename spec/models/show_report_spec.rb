# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ShowReport do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', status: 'active') }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'O', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent)
  end

  def build_report(attrs = {})
    described_class.new({
      lead_event: lead, conducted_by: director, reported_by: agent,
      conducted_at: Time.current, source: 'voice', objections: ['кухня', 'первый этаж']
    }.merge(attrs))
  end

  def create_report!(attrs = {})
    build_report(attrs).tap(&:save!)
  end

  it 'валидна с минимальным набором и pending по умолчанию' do
    r = build_report
    expect(r).to be_valid
    expect(r.status_pending_confirm?).to be(true)
    expect(r.outcome_thinking?).to be(true)
  end

  it 'OUTCOME_LABELS покрывает все исходы' do
    expect(described_class::OUTCOME_LABELS.keys).to match_array(described_class.outcomes.keys)
  end

  it '#confirm! и #cancel! идемпотентны по статусу' do
    r = create_report!
    r.confirm!
    expect(r.status_confirmed?).to be(true)
    expect { r.cancel! }.not_to(change { r.reload.status })
  end

  it '#conducted_by_director? по роли показывающего' do
    expect(build_report.conducted_by_director?).to be(true)
    expect(build_report(conducted_by: agent).conducted_by_director?).to be(false)
  end

  it '#toggle_conductor! переключает между reporter и director' do
    r = create_report!
    r.toggle_conductor!(reporter: agent, director: director)
    expect(r.conducted_by).to eq(agent)
    r.toggle_conductor!(reporter: agent, director: director)
    expect(r.conducted_by).to eq(director)
  end

  it 'soft-delete скрывает запись из default_scope' do
    r = create_report!
    r.update!(deleted_at: Time.current)
    expect(described_class.find_by(id: r.id)).to be_nil
    expect(described_class.unscoped.find(r.id)).to eq(r)
  end

  it '.confirmed_in и .for_property' do
    property = create(:property)
    r = create_report!(property: property, status: 'confirmed', conducted_at: 2.days.ago)
    create_report!(property: property, conducted_at: 2.days.ago)
    expect(described_class.confirmed_in(3.days.ago..Time.current)).to contain_exactly(r)
    expect(described_class.for_property(property).count).to eq(2)
  end

  it '#objections_list чистит пустые и приводит к строкам' do
    expect(build_report(objections: ['Кухня ', nil, '', 'этаж']).objections_list).to eq(['кухня', 'этаж'])
  end

  describe '#expire!' do
    it 'pending > часа снимается, confirmed не трогается' do
      stale = create_report!(created_at: 2.hours.ago)
      fresh = create_report!(created_at: 5.minutes.ago)
      done  = create_report!(created_at: 3.hours.ago).confirm!

      described_class.expired_candidates(older_than: 1.hour.ago).find_each(&:expire!)

      expect(stale.reload.status_expired?).to be(true)
      expect(fresh.reload.status_pending_confirm?).to be(true)
      expect(done.reload.status_confirmed?).to be(true)
    end
  end
end
