# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatResponder do
  # Нит-пик ревью #206: маршрутизация после estimate_property_valuation
  # (request_specialist_evaluation vs qualify_lead) закреплена спеком,
  # чтобы промпт и описания тулов не разъезжались молча.
  let(:conversation) { instance_double(Conversation, metadata: {}) }

  def prompt
    described_class.new(conversation).full_system_prompt
  end

  it 'после оценки предлагает передачу специалисту через request_specialist_evaluation' do
    expect(prompt).to include('request_specialist_evaluation')
    expect(prompt).to match(/передать запрос на точную оценку нашим специалистам/i)
  end

  it 'сохраняет upsell-сценарии qualify_lead (cma/investment/buyer_scan)' do
    expect(prompt).to include('qualify_lead')
    expect(prompt).to include('service_type=`cma`')
    expect(prompt).to include('service_type=`investment`')
    expect(prompt).to include('service_type=`buyer_scan`')
  end

  it 'требует ровно один тул на сценарий — никогда оба' do
    expect(prompt).to match(/ровно один тул/i)
    expect(prompt).to match(/никогда оба/i)
  end

  it 'различает недоступность поиска (null) и малое покрытие (0–2): null — не упоминать прошлые оценки' do
    expect(prompt).to match(/null — поиск по прошлым оценкам недоступен/i)
    expect(prompt).to match(/0.2 — честно скажи, что похожих оценок мало/i)
  end
end
