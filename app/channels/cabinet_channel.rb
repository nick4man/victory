# frozen_string_literal: true

# A7 Phase 2: real-time updates для personal cabinet.
# Push events when:
#   - Inquiry status changes (status, priority, agent_id assignment)
#   - PropertyValuation completes (status: 'completed')
#
# Subscription: stream_for current_cabinet_user (User record).
# Каждый кабинет — один stream per user. Frontend (cabinet stimulus
# controller) обрабатывает payload и обновляет DOM без reload.
#
# Pattern mirrors ValuationChannel (token-scoped), но scope здесь —
# User, потому что кабинет показывает множество records одного user'а.
#
# Mirror_pattern_ref: app/channels/valuation_channel.rb
# Broadcast_caller_refs:
#   - Inquiry#broadcast_status_change (after_update on status)
#   - PropertyValuation#broadcast_completion (after_update on status)
class CabinetChannel < ApplicationCable::Channel
  def subscribed
    user_id = params[:user_id].to_i
    return reject if user_id.zero?

    # Auth — session-based identity. ApplicationCable::Connection
    # уже should have set current_cabinet_user_id (если delegated cookie auth).
    # На случай чтобы не блокировать unauthenticated users, also reject
    # если incoming user_id mismatches session.
    expected = connection.current_cabinet_user_id rescue nil
    return reject if expected.present? && expected != user_id

    user = User.find_by(id: user_id, active: true, deleted_at: nil)
    return reject if user.nil?

    stream_for user
  end
end
