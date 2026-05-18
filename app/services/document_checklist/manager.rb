# frozen_string_literal: true

module DocumentChecklist
  # Phase 4B — DocumentChecklist::Manager — service handling /doc command
  # interactions. Parses shorthand syntax + applies lifecycle transitions с
  # idempotency + actor-tracking.
  #
  # Syntax overview (parsed via Tokenizer):
  #   /doc                              — full checklist status
  #   /doc passport+                    — kind=passport_main → received
  #   /doc passport-                    — → not_requested (revert)
  #   /doc snils?                       — → requested (запросить клиента)
  #   /doc egrn+verified                — → received + verify (atomic leap)
  #   /doc contract=approved            — → approved (legal/director leap)
  #   /doc poa@reject:no_notary         — → rejected с reason
  #   /doc passport+ snils+ inn+        — batch mark several
  #
  # Authorization: manager OR assignee лида может modify (см. /stage,/note
  # symmetry). Director/admin может всё (через manager_or_director?).
  #
  # Idempotency: re-marking same state = no-op + friendly hint.
  class Manager
    Result = Struct.new(:success, :records, :message, keyword_init: true) do
      def success?
        success
      end
    end

    def initialize(lead_event:, actor:)
      @lead = lead_event
      @actor = actor
    end

    # Apply parsed tokens к lead's checklist.
    # @param tokens [Array<Hash>] от Tokenizer
    # @return [Result]
    def apply(tokens)
      return Result.new(success: false, records: [], message: 'Пустой список действий') if tokens.empty?

      ::DocumentRequirement.transaction do
        records = tokens.map { |t| apply_token(t) }.compact
        Result.new(success: true, records: records,
                   message: "Обновлено: #{records.size} документ(ов)")
      end
    rescue ApplyError => e
      Result.new(success: false, records: [], message: e.message)
    end

    # Format full checklist view для /doc без args.
    # @return [String] HTML-safe (для parse_mode=HTML)
    def format_status
      reqs = ::DocumentRequirement.where(lead_event_id: @lead.id).order(:kind)
      return '📋 Чек-лист пуст. Сгенерируй автоматически: <code>/doc init</code>' if reqs.empty?

      groups = reqs.group_by(&:status)
      total = reqs.size
      done  = reqs.count { |r| %w[verified approved].include?(r.status) }
      progress_pct = total.positive? ? (done * 100.0 / total).round : 0

      lines = [
        "📋 <b>Документы по лиду ##{@lead.id}</b>",
        "Прогресс: <b>#{done}/#{total}</b> готовы (#{progress_pct}%)",
        ''
      ]

      append_group(lines, groups, %w[approved verified], '✅ ГОТОВЫ:', show_actor: true)
      append_group(lines, groups, %w[received], '📥 ПОЛУЧЕНЫ (не verified):', show_actor: true)
      append_group(lines, groups, %w[requested], '⏳ ЗАПРОШЕНЫ:', show_sla: true)
      append_group(lines, groups, %w[not_requested], '❓ НЕ ЗАПРОШЕНЫ:')
      append_group(lines, groups, %w[rejected], '🚫 ОТКЛОНЕНЫ:', show_actor: true)

      lines.join("\n")
    end

    class ApplyError < StandardError; end

    private

    def apply_token(token)
      kind = token[:kind]
      action = token[:action]

      record = find_or_init_record(kind)

      case action
      when :received   then mark_received(record, token)
      when :requested  then mark_requested(record)
      when :not_requested then mark_not_requested(record)
      when :verified   then mark_verified(record, token)
      when :approved   then mark_approved(record)
      when :rejected   then mark_rejected(record, token)
      else
        raise ApplyError, "Неизвестное действие: #{action} для #{kind}"
      end
      record
    end

    def find_or_init_record(kind)
      ::DocumentRequirement.find_or_initialize_by(lead_event_id: @lead.id, kind: kind) do |r|
        r.status = 'not_requested'
      end
    end

    def mark_received(record, token)
      already = record.status_received? || record.status_verified? || record.status_approved?
      record.save! if record.new_record? # ensure persistence
      record.receive! unless already
      mark_verified(record, token) if token[:also] == :verified
    end

    def mark_requested(record)
      record.save! if record.new_record?
      record.request!(by: @actor)
    end

    def mark_not_requested(record)
      if record.new_record?
        # Nothing to revert; just persist as not_requested.
        record.save!
      else
        record.update!(status: 'not_requested', requested_at: nil, received_at: nil)
      end
    end

    def mark_verified(record, _token)
      record.save! if record.new_record?
      record.receive! if record.status_not_requested? || record.status_requested?
      record.verify!(by: @actor)
    end

    def mark_approved(record)
      record.save! if record.new_record?
      record.receive! if record.status_not_requested? || record.status_requested?
      record.verify!(by: @actor) unless record.status_verified? || record.status_approved?
      record.approve!(by: @actor)
    end

    def mark_rejected(record, token)
      record.save! if record.new_record?
      record.reject!(by: @actor, reason: token[:reason])
    end

    def append_group(lines, groups, statuses, header, show_actor: false, show_sla: false)
      records = statuses.flat_map { |s| Array(groups[s]) }
      return if records.empty?

      lines << "<b>#{header}</b>"
      records.each do |r|
        line = "  • #{r.ru_label}"
        line += format_actor_suffix(r) if show_actor
        line += format_sla_suffix(r)   if show_sla
        lines << line
      end
      lines << ''
    end

    def format_actor_suffix(record)
      actor = record.verified_by || record.approved_by || record.requested_by
      when_at = record.verified_at || record.approved_at || record.received_at
      return '' unless actor && when_at

      " — by #{actor.mention}, #{when_at.strftime('%d.%m %H:%M')}"
    end

    def format_sla_suffix(record)
      factor = record.overdue_factor
      return '' unless factor

      if factor >= 1.0
        " — ⚠️ просрочка #{((factor - 1.0) * 100).round}%"
      else
        remain = ((1.0 - factor) * record.effective_sla / 3600).round(1)
        " — ⏰ ещё #{remain}ч"
      end
    end
  end
end
