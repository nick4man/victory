# frozen_string_literal: true

module CrmCards
  # Advisory lock (Postgres) — сериализация ВХОДА ExportJob: второй job не
  # начнёт попытку, пока живой lock занят. Это всё, что lock гарантирует:
  # разрыв DB-соединения отпускает session-level lock раньше, чем завершится
  # живой HTTP-вызов importClient, поэтому по свободному lockу живость
  # попытки не судить — retry из 'exporting' запрещён безусловно, а
  # восстановление идёт через ручную сверку с CRM (Workflow#retry_export!,
  # ревью PR #210).
  #
  # Сессионный, а не транзакционный: попытка живёт дольше отдельных
  # транзакций (with_lock вокруг финализации), а смерть процесса закрывает
  # соединение и отпускает lock мгновенно.
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

      def release(card)
        ActiveRecord::Base.connection.select_value(
          "SELECT pg_advisory_unlock(#{NAMESPACE}, #{card.id.to_i})"
        )
      end
    end
  end
end
