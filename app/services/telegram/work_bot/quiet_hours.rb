# frozen_string_literal: true

module Telegram
  module WorkBot
    # Окно «тихих часов» 21:00–07:00 Moscow per регламенту АН.
    #
    # Используется проактивными уведомлениями (SLA-watchdog, assignee DM):
    # если active? — отправка откладывается через Sidekiq до `next_window_start`.
    # Реактив (callback-acks, reply на команды, публикация новых лидов) — НЕ под
    # quiet hours: лид от клиента в 22:00 должен попасть в #ДИСПЕТЧЕРСКОЙ сразу.
    #
    # Moscow не использует DST с 2014 — Time.zone стабильна круглый год.
    #
    # API:
    #   QuietHours.active?                    # → true 21:00-06:59 Moscow
    #   QuietHours.next_window_start          # → Time ближайший 07:00 Moscow
    #   QuietHours.next_window_start(from: t) # для тестов / фикс-времени
    class QuietHours
      WORK_START_HOUR = 7  # включительно
      WORK_END_HOUR   = 21 # эксклюзивно — quiet начинается в 21:00 ровно
      TIME_ZONE       = 'Moscow'

      class << self
        # @return [Boolean] true если сейчас тихие часы
        def active?(at: Time.current)
          h = at.in_time_zone(TIME_ZONE).hour
          h < WORK_START_HOUR || h >= WORK_END_HOUR
        end

        # Ближайший момент начала рабочих часов (07:00 Moscow).
        # Если сейчас уже в рабочих часах — возвращает ОЗНАЧАЮЩИЙ что defer не нужен;
        # caller должен сначала проверять active? и только потом next_window_start.
        # @return [ActiveSupport::TimeWithZone]
        def next_window_start(from: Time.current)
          tz_now = from.in_time_zone(TIME_ZONE)
          today_seven = tz_now.change(hour: WORK_START_HOUR, min: 0, sec: 0)
          tz_now.hour < WORK_START_HOUR ? today_seven : today_seven + 1.day
        end

        # Удобный wrapper: если active? — возвращает next_window_start, иначе nil.
        # Используется в SLA-jobs: `wait_until = QuietHours.defer_until` → `set(wait_until:).perform_later`.
        # @return [Time, nil]
        def defer_until(at: Time.current)
          active?(at: at) ? next_window_start(from: at) : nil
        end
      end
    end
  end
end
