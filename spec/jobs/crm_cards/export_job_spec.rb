# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::ExportJob do
  it 'передаёт карточку конвейеру' do
    card = instance_double(CrmCard, sandbox?: false)
    workflow = instance_double(CrmCards::Workflow, export!: nil)
    allow(CrmCard).to receive(:find_by).with(id: 42).and_return(card)
    allow(CrmCards::Workflow).to receive(:new).and_return(workflow)

    described_class.perform_now(42)

    expect(workflow).to have_received(:export!).with(card)
  end

  it 'неожиданная ошибка не пробрасывается: автоповтор ApplicationJob завёл бы вторую заявку' do
    allow(CrmCard).to receive(:find_by).and_raise(StandardError, 'boom')

    expect { described_class.perform_now(42) }.not_to raise_error
  end
end
