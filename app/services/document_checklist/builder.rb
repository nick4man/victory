# frozen_string_literal: true

module DocumentChecklist
  # Phase 4C — Auto-instantiate DocumentRequirement checklist для lead_event.
  #
  # Workflow:
  #   1. Resolve template key из lead.lead_ref (Inquiry/Property) контекста
  #   2. Lookup template из TemplateRegistry
  #   3. Для каждого required kind → create DocumentRequirement (idempotent
  #      через unique constraint)
  #   4. Для каждого optional kind → evaluate condition против context;
  #      если true → create
  #   5. Apply dependency graph (DEPENDS_ON) — cascade prerequisites
  #
  # Idempotency: re-running на том же лиде skip'ает existing DR (unique
  # (lead_event_id, kind) constraint catches dupes). Можно вызывать
  # multiple times при context changes (e.g. lead.metadata['has_mortgage']
  # = true после initial /doc init).
  #
  # @example
  #   builder = DocumentChecklist::Builder.new(lead_event: lead, actor: tu)
  #   result = builder.call
  #   result.success?     # => true
  #   result.created      # => [<DocumentRequirement>, ...]
  #   result.skipped      # => ['passport_main: already exists']
  #   result.template_key # => 'flat_sale'
  class Builder
    Result = Struct.new(:success, :created, :skipped, :template_key, :error, keyword_init: true) do
      def success?
        success
      end
    end

    def initialize(lead_event:, actor: nil)
      @lead = lead_event
      @actor = actor
    end

    def call
      key = resolve_template_key
      template = TemplateRegistry.lookup(key)
      context = build_context

      created = []
      skipped = []

      ::DocumentRequirement.transaction do
        Array(template[:required]).each do |kind|
          dr = build_requirement(kind)
          if dr
            created << dr
            apply_dependency_cascade(kind, created, skipped)
          else
            skipped << "#{kind}: already exists"
          end
        end

        Array(template[:optional]).each do |kind, condition|
          next unless condition.call(context)

          dr = build_requirement(kind)
          if dr
            created << dr
          else
            skipped << "#{kind}: already exists (optional)"
          end
        end
      end

      Result.new(success: true, created: created, skipped: skipped,
                 template_key: key, error: nil)
    rescue StandardError => e
      Rails.logger.error("[DocumentChecklist::Builder] #{e.class}: #{e.message}")
      Result.new(success: false, created: [], skipped: [],
                 template_key: nil, error: e.message)
    end

    private

    # Resolves template key из контекста lead.
    # Priority:
    #   1. Property → property_type.slug + deal_type → 'flat_sale'
    #   2. Inquiry → inquiry_type → 'mortgage' / 'evaluation'
    #   3. Fallback → 'default_sale'
    def resolve_template_key
      property = property_from_lead
      if property
        slug = property.property_type&.slug.to_s
        deal = property.deal_type.to_s
        key  = "#{slug}_#{deal}"
        return key if TemplateRegistry.keys.include?(key)
      end

      inquiry = inquiry_from_lead
      if inquiry
        case inquiry.inquiry_type
        when 'mortgage'  then return 'mortgage'
        when 'evaluation' then return 'evaluation'
        end
      end

      'default_sale'
    end

    def property_from_lead
      ref = @lead.lead_ref
      return nil unless ref

      ref.is_a?(Property) ? ref : ref.try(:property)
    end

    def inquiry_from_lead
      ref = @lead.lead_ref
      return nil unless ref

      ref.is_a?(Inquiry) ? ref : nil
    end

    # Context для optional condition evaluation. Reads из lead.metadata + inquiry.
    def build_context
      meta = @lead.metadata || {}
      inquiry = inquiry_from_lead
      {
        client_marital_status: meta['client_marital_status'] || inquiry&.metadata&.dig('marital_status'),
        has_proxy: meta['has_proxy'] == true,
        has_mortgage: meta['has_mortgage'] == true || inquiry&.inquiry_type_mortgage?,
        has_minor_owner: meta['has_minor_owner'] == true
      }.compact
    end

    # Create DocumentRequirement; rescue uniqueness violation (idempotent).
    # @return [DocumentRequirement, nil] — nil если skip (already exists)
    #
    # IMPORTANT: оборачиваем в savepoint (requires_new: true) — иначе
    # ActiveRecord::RecordNotUnique abort'ит outer transaction в PG
    # ('current transaction is aborted' для последующих queries). Savepoint
    # isolates failure только к nested transaction.
    def build_requirement(kind)
      ::DocumentRequirement.transaction(requires_new: true) do
        return ::DocumentRequirement.create!(
          lead_event_id: @lead.id,
          kind: kind,
          status: 'not_requested',
          requested_by_id: @actor&.id
        )
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    # Phase 4A DEPENDS_ON cascade: при создании contract_sale → ensures
    # egrn_excerpt + passport_main также созданы.
    def apply_dependency_cascade(kind, created, skipped)
      prerequisites = ::DocumentRequirement::DEPENDS_ON[kind] || []
      prerequisites.each do |prereq|
        dr = build_requirement(prereq)
        if dr
          created << dr
        else
          skipped << "#{prereq}: cascade — already exists"
        end
      end
    end
  end
end
