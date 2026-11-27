# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::DashboardPagination do
  describe '.leads_page_callback / .staff_page_callback' do
    it 'кодирует страницу в callback_data по контракту issue #277' do
      expect(described_class.leads_page_callback(3)).to eq('dashboard:leads:p:3')
      expect(described_class.staff_page_callback(12)).to eq('dashboard:staff:p:12')
    end

    it 'укладывается в лимит Telegram 64 байта даже на больших страницах' do
      expect(described_class.leads_page_callback(999_999).bytesize).to be <= 64
      expect(described_class.staff_page_callback(999_999).bytesize).to be <= 64
    end

    it 'нормализует страницу < 1 к первой' do
      expect(described_class.leads_page_callback(0)).to eq('dashboard:leads:p:1')
      expect(described_class.staff_page_callback(-5)).to eq('dashboard:staff:p:1')
    end
  end

  describe '.parse_page' do
    it 'разбирает args страничной навигации' do
      expect(described_class.parse_page(%w[leads p 2])).to eq([:leads, 2])
      expect(described_class.parse_page(%w[staff p 7])).to eq([:staff, 7])
    end

    it 'нормализует мусорный номер страницы к 1' do
      expect(described_class.parse_page(%w[leads p 0])).to eq([:leads, 1])
      expect(described_class.parse_page(['leads', 'p', 'abc'])).to eq([:leads, 1])
      expect(described_class.parse_page(%w[staff p])).to eq([:staff, 1])
    end

    it 'возвращает nil для карточек сущностей и чужих секций' do
      expect(described_class.parse_page(%w[staff 123])).to be_nil
      expect(described_class.parse_page(%w[lead 45])).to be_nil
      expect(described_class.parse_page(%w[tasks p 1])).to be_nil
      expect(described_class.parse_page(['leads'])).to be_nil
    end
  end

  describe '.nav_row' do
    def callbacks(row)
      row.map { |b| b[:callback_data] }
    end

    it 'первая страница — без ◀️, с ▶️ на вторую' do
      row = described_class.nav_row(:leads, 1, 4)
      expect(callbacks(row)).to eq(['dashboard:leads:p:1', 'dashboard:leads:p:2'])
      expect(row.map { |b| b[:text] }).to eq(['1/4', '▶️'])
    end

    it 'последняя страница — без ▶️, с ◀️ на предыдущую' do
      row = described_class.nav_row(:leads, 4, 4)
      expect(callbacks(row)).to eq(['dashboard:leads:p:3', 'dashboard:leads:p:4'])
      expect(row.map { |b| b[:text] }).to eq(['◀️', '4/4'])
    end

    it 'средняя страница — обе стрелки, индикатор ведёт на ту же страницу' do
      row = described_class.nav_row(:staff, 2, 4)
      expect(callbacks(row)).to eq(['dashboard:staff:p:1', 'dashboard:staff:p:2', 'dashboard:staff:p:3'])
      expect(row.map { |b| b[:text] }).to eq(['◀️', '2/4', '▶️'])
    end

    it 'единственная страница — только индикатор' do
      row = described_class.nav_row(:staff, 1, 1)
      expect(callbacks(row)).to eq(['dashboard:staff:p:1'])
    end
  end
end
