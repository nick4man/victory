# frozen_string_literal: true

module DocumentChecklist
  # Phase 4B — Parser для /doc command syntax.
  #
  # Token forms (each space-separated word):
  #   passport+           → kind=passport_main, action=:received
  #   passport-           → action=:not_requested (revert)
  #   passport?           → action=:requested
  #   passport+verified   → action=:received, also=:verified
  #   passport=approved   → action=:approved
  #   passport@reject:no_notary → action=:rejected, reason='no_notary'
  #
  # Aliases (KIND_ALIASES) — short-forms ↔ canonical enum kind.
  class Tokenizer
    Result = Struct.new(:tokens, :errors, keyword_init: true) do
      def success?
        errors.empty?
      end
    end

    SUFFIX_RE = /
      \A
      (?<base>[\p{L}\p{N}_]+)            # kind alias or full enum value
      (?:
        (?<short>[+\-?])                 # plus minus or question
        (?:(?<combo>verified|approved))? # optional combined action
      |
        =(?<set>approved|verified|rejected)
      |
        @reject:(?<reason>.+)
      )
      \z
    /x.freeze

    def initialize(args)
      @args = args.to_s.strip
    end

    def parse
      return Result.new(tokens: [], errors: ['пустой ввод']) if @args.empty?

      tokens = []
      errors = []

      @args.split(/\s+/).each do |word|
        m = SUFFIX_RE.match(word.downcase)
        unless m
          errors << "не понимаю: <code>#{escape(word)}</code>"
          next
        end

        kind = resolve_kind(m[:base])
        unless kind
          errors << "не знаю тип документа: <code>#{escape(m[:base])}</code>"
          next
        end

        action, combo, reason = nil, nil, nil
        if m[:short]
          action = { '+' => :received, '-' => :not_requested, '?' => :requested }[m[:short]]
          combo  = m[:combo]&.to_sym
        elsif m[:set]
          action = m[:set].to_sym
        elsif m[:reason]
          action = :rejected
          reason = m[:reason].strip
        end

        token = { kind: kind, action: action }
        token[:also]   = combo  if combo
        token[:reason] = reason if reason
        tokens << token
      end

      Result.new(tokens: tokens, errors: errors)
    end

    private

    # Принимаем как aliases (pass, egrn, ипотека) так и full enum values (passport_main).
    def resolve_kind(base)
      return base if ::DocumentRequirement.kinds.key?(base)

      ::DocumentRequirement::KIND_ALIASES[base]
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
