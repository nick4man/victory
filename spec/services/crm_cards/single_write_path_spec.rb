# frozen_string_literal: true

require 'rails_helper'

# Заявка попадает в CRM только через модерацию. Любой второй вызов
# import_client — обход модерации, даже если он «временный» или «для
# теста». До 14.09.26 метод не вызывался нигде, и заявки с сайта в CRM не
# уходили вовсе; теперь путь один, и спека держит его одним.
RSpec.describe 'единственный путь записи заявок в CRM' do
  it 'Topnlab::Client#import_client вызывается только из CrmCards::LeadExporter' do
    callers = Dir[Rails.root.join('app/**/*.rb')].select { |path| File.read(path).match?(/\.import_client\b/) }
                                                 .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }

    expect(callers).to eq(['app/services/crm_cards/lead_exporter.rb'])
  end
end
