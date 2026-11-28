# frozen_string_literal: true

module Telegram
  module WorkBot
    # Issue #277 — метрики и под-списки карточки сотрудника (dashboard:staff:<id>).
    #
    # Все счётчики — существующие scopes (Task.status_open/overdue,
    # LeadEvent.real/open/awaiting_first_contact), точечные count-запросы по
    # одному сотруднику — N+1 нет по построению. SLA-формула «первый контакт
    # ≤ 30 мин» повторяет Kpi::StaffSnapshot (EXTRACT EPOCH <= 1800), но
    # считается live за 7 дней, а не по дневному снапшоту.
    class DashboardStaffMetrics
      LEADS_LIMIT = 6
      TASKS_LIMIT = 6
      FC_WINDOW = 7.days
      FC_SLA_SEC = 1800 # 30 минут — тот же порог, что в Kpi::StaffSnapshot

      attr_reader :staff

      def initialize(staff)
        @staff = staff
      end

      def tasks_open
        ::Task.status_open.where(assignee_id: staff.id).count
      end

      def tasks_overdue
        ::Task.overdue.where(assignee_id: staff.id).count
      end

      def tasks_done_today
        ::Task.status_done.where(assignee_id: staff.id, updated_at: Time.current.all_day).count
      end

      def leads_open
        LeadEvent.real.open.where(assigned_to_id: staff.id).count
      end

      def leads_awaiting_fc
        awaiting_fc_scope.count
      end

      def leads_fc_overdue
        awaiting_fc_scope.where('assigned_at < ?', 30.minutes.ago).count
      end

      # Назначено за 7 дней / из них первый контакт ≤ 30 мин.
      def fc_week
        base = LeadEvent.real.where(assigned_to_id: staff.id, assigned_at: FC_WINDOW.ago..Time.current)
        in_sla = base.where.not(first_contact_at: nil)
                     .where('EXTRACT(EPOCH FROM (first_contact_at - assigned_at)) <= ?', FC_SLA_SEC)
        [base.count, in_sla.count]
      end

      # Открытые лиды сотрудника — кнопки-переходы в карточку лида.
      def open_leads
        LeadEvent.real.open.where(assigned_to_id: staff.id)
                 .order(updated_at: :desc, id: :desc)
                 .limit(LEADS_LIMIT)
      end

      # Открытые задачи сотрудника — читаемый список (у задач нет своей
      # карточки: task:<id> — action-callback done/start, не drill-down).
      def open_tasks
        ::Task.status_open.where(assignee_id: staff.id)
              .order(Arel.sql('due_at ASC NULLS LAST'), id: :asc)
              .limit(TASKS_LIMIT)
      end

      private

      def awaiting_fc_scope
        LeadEvent.real.awaiting_first_contact.where(assigned_to_id: staff.id)
      end
    end
  end
end
