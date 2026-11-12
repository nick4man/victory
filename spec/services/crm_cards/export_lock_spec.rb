# frozen_string_literal: true

require 'rails_helper'
require 'pg'

# Сериализация владения попыткой выгрузки: advisory lock виден между
# сессиями, смерть владельца (закрытие соединения) отпускает его.
# «Другой процесс» — сырое PG-соединение вне пула ActiveRecord: рельсовые
# транзакционные фикстуры шарят одно соединение между тредами, и через пул
# вторую сессию не получить.
RSpec.describe CrmCards::ExportLock do
  let(:card) { instance_double(CrmCard, id: 42_001) }

  def raw_pg
    cfg = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(dbname: cfg[:database], host: cfg[:host], user: cfg[:username],
               password: cfg[:password], port: cfg[:port])
  end

  def try_acquire_raw(conn)
    conn.exec("SELECT pg_try_advisory_lock(#{described_class::NAMESPACE}, #{card.id})").getvalue(0, 0) == 't'
  end

  def in_progress_raw(conn)
    acquired = try_acquire_raw(conn)
    conn.exec("SELECT pg_advisory_unlock(#{described_class::NAMESPACE}, #{card.id})") if acquired
    !acquired
  end

  it 'лок занят: вторая сессия не захватывает, in_progress? правда, владелец непотревожен' do
    other = raw_pg
    expect(described_class.try_acquire(card)).to be(true)
    expect(try_acquire_raw(other)).to be(false)
    expect(in_progress_raw(other)).to be(true)
    # проверка in_progress? захватила и отпустила временный лок — владельцу нетронут
    expect(try_acquire_raw(other)).to be(false)
  ensure
    other&.close
    described_class.release(card)
  end

  it 'лок свободен: in_progress? ложь, вторая сессия захватывает' do
    other = raw_pg
    expect(in_progress_raw(other)).to be(false)
    expect(try_acquire_raw(other)).to be(true)
  ensure
    other&.exec("SELECT pg_advisory_unlock(#{described_class::NAMESPACE}, #{card.id})")
    other&.close
  end
end
