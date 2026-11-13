# frozen_string_literal: true

module CrmCards
  # Advisory lock (Postgres) — двойная страховка сериализации выгрузки:
  # 1) вход ExportJob: второй job не начнёт попытку, пока живой lock занят;
  # 2) retry stale-карточки: свободный lock = сессия владельца закрыта,
  #    владелец доказуемо мёртв.
  #
  # Главная сериализация — статусная строка (Workflow#retry_export!):
  # свежий 'exporting' блокирует retry безусловно, потому что разрыв
  # соединения отпускает session-level lock раньше, чем завершится живой
  # HTTP-вызов importClient — по одному lock живость попытки не судить
  # (ревью PR #210).
  #
  # Сессионный, а не транзакционный: попытка живёт дольше отдельных
  # транзакций (with_lock вокруг финализации), а смерть процесса закрывает
  # соединение и отпускает lock мгновенно.
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
