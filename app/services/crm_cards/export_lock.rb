# frozen_string_literal: true

module CrmCards
  # Advisory lock (Postgres) на всё время выгрузки карточки — единственный
  # владелец попытки на всём протяжении сетевых вызовов к Topnlab.
  #
  # Сессионный, а не транзакционный: попытка живёт дольше отдельных
  # транзакций (with_lock вокруг финализации), а смерть процесса закрывает
  # соединение и отпускает лок мгновенно — ручной «Повторить» для упавшей
  # попытки работает без 15-минутного stale-окна. Зависший процесс держит
  # лок честно: retry откажет («выгрузка ещё выполняется»), а не заведёт
  # вторую заявку в CRM (неидемпотентный importClient).
  #
  # pg_advisory_lock_held видит только локи своей сессии, поэтому проверка
  # «попытка ещё жива» из другого процесса — попытка захвата: удалось
  # захватить (и сразу отпустить) = никто не владеет.
  class ExportLock
    NAMESPACE = 727_401 # произвольная константа пространства ключей

    class << self
      # Неблокирующий захват; false — попыткой уже владеет другой процесс
      # (или эта же сессия, см. specs).
      def try_acquire(card)
        ActiveRecord::Base.connection.select_value(
          "SELECT pg_try_advisory_lock(#{NAMESPACE}, #{card.id.to_i})"
        )
      end

      # Тrue, если владелец жив и держит лок. Захватившему сразу отпускает.
      def in_progress?(card)
        acquired = try_acquire(card)
        release(card) if acquired
        !acquired
      end

      def release(card)
        ActiveRecord::Base.connection.select_value(
          "SELECT pg_advisory_unlock(#{NAMESPACE}, #{card.id.to_i})"
        )
      end
    end
  end
end
