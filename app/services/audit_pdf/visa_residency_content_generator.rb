# frozen_string_literal: true

module AuditPdf
  # B2 Track 3 — генерирует EN visa/residency/tax-секцию для foreign-audit
  # отчёта. LLM вызывается через `Llm::OmniClient.complete(chain: :analysis)`
  # с context из конкретной PropertyValuation (segment, price, ROI, verdict).
  # Cost economy (per feedback_llm_cost_economy): free providers первыми;
  # cache в `PropertyValuation.metadata['visa_chapter_en']` → один LLM-вызов
  # на audit за весь жизненный цикл отчёта.
  #
  # На failure → returns nil; ParserJob/AuditPdfGenerator gracefully
  # fallback на static legal disclaimer из en.yml.
  class VisaResidencyContentGenerator
    REQUEST_MAX_TOKENS = 1500
    REQUEST_TIMEOUT_SEC = 30

    def self.call(valuation)
      new(valuation).call
    end

    def initialize(valuation)
      @v = valuation
      @audit = (valuation.evaluation_data || {})['audit'] || {}
      @mc = (valuation.evaluation_data || {})['monte_carlo'] || {}
    end

    # @return [Hash, nil] structured EN content:
    #   {
    #     'investment_visa'    => 'Investment-based residency text…',
    #     'tax_obligations'    => 'Non-resident tax info…',
    #     'residency_pathways' => 'Other pathways…',
    #     'disclaimer'         => 'Legal disclaimer…'
    #   }
    def call
      cached = @v.metadata&.[]('visa_chapter_en')
      return cached if cached.is_a?(Hash) && cached['investment_visa'].present?

      response = invoke_llm
      parsed = parse_json(response)
      return nil if parsed.nil?

      # Persist в metadata (jsonb)
      meta = (@v.metadata || {}).merge('visa_chapter_en' => parsed)
      @v.update_columns(metadata: meta)
      parsed
    rescue StandardError => e
      Rails.logger.warn("[VisaResidencyContentGenerator] #{e.class}: #{e.message}")
      nil
    end

    private

    def invoke_llm
      client = Llm::OmniClient.new
      result = client.complete(
        build_messages,
        chain: :analysis,
        max_tokens: REQUEST_MAX_TOKENS,
        timeout: REQUEST_TIMEOUT_SEC
      )
      result[:content].to_s
    end

    def build_messages
      [
        { role: 'system', content: system_prompt },
        { role: 'user',   content: user_prompt }
      ]
    end

    def system_prompt
      <<~PROMPT
        You are a neutral expert advisor on Russian Federation immigration, tax,
        and residency rules for FOREIGN property investors. You write concise,
        actionable English text — not legal advice, just orientation.

        Audience: international investor considering Russian property purchase.
        Tone: factual, neutral, no marketing language. Use plain English (CEFR B2),
        avoid jargon. Always include practical implications, not just regulations.

        Output STRICT JSON only, no preamble, no markdown fences. Schema:
        {
          "investment_visa": "<200-300 word section about Russian investment-based
            residency options applicable to property buyers. Include: minimum
            investment thresholds (e.g. FZ-115 of 2023 for 30M+ RUB), processing
            time, required documents, validity period. Connect to the property
            price in context (does it qualify?).>",
          "tax_obligations": "<150-200 words on tax obligations for non-resident
            property owners: NDFL rate (30% for non-residents on rental income),
            property tax (~0.1-2% of cadastral value), reporting deadlines, double
            taxation treaty options. Specific to the segment described.>",
          "residency_pathways": "<100-150 words on alternative residency pathways
            relevant to property investors: highly-qualified specialist visa,
            education-based, family reunification — when each applies.>",
          "disclaimer": "<one paragraph, max 80 words, legal-style disclaimer that
            this is informational only, rules change frequently, consult a licensed
            Russian lawyer before acting.>"
        }

        Do NOT invent specific case studies or statistics. Use general legal
        framework (FZ-115, Tax Code Art. 224, 207) where appropriate. If the
        property price doesn't qualify for fast-track residency, say so plainly.
      PROMPT
    end

    def user_prompt
      price_rub = @audit['price_total'].to_f
      price_usd = price_rub > 0 ? (price_rub / (CurrencyRatesService.call[:usd] || 95).to_f).round : nil
      segment = segment_label(price_rub)
      verdict = @audit['verdict'].to_s
      address = (@v.address.presence || @audit['complex_name']).to_s.truncate(120)

      <<~CTX
        Property context for the visa/residency section:

        Location: #{address}
        Price (RUB): #{price_rub.to_i}
        Price (USD): #{price_usd ? '$' + price_usd.to_s : 'n/a'}
        Segment: #{segment}
        Audit verdict: #{verdict.presence || 'NEUTRAL'}
        Recommended strategy: #{@mc['recommended_strategy']}

        Generate the four-section JSON. Connect the analysis to this specific
        property's price — does it qualify for fast-track residency (30M+ RUB
        threshold under FZ-115)? What's the tax burden on rental income at
        this price point? Be specific to this case, not generic.
      CTX
    end

    def segment_label(price_rub)
      case price_rub.to_f
      when 0..5_000_000        then 'budget'
      when 5_000_000..15_000_000 then 'mid-market'
      when 15_000_000..30_000_000 then 'premium'
      else                            'ultra-premium (qualifies for fast-track residency)'
      end
    end

    def parse_json(raw)
      return nil if raw.blank?

      # LLM может вернуть JSON с markdown-fence или с preamble. Cleanup.
      cleaned = raw.strip
                   .sub(/\A```(?:json)?\s*/, '')
                   .sub(/\s*```\z/, '')
                   .strip

      data = JSON.parse(cleaned)
      return nil unless data.is_a?(Hash)
      return nil if data['investment_visa'].to_s.strip.length < 50

      # Whitelist keys чтобы не сохранить arbitrary mess в metadata
      data.slice('investment_visa', 'tax_obligations', 'residency_pathways', 'disclaimer')
    rescue JSON::ParserError => e
      Rails.logger.warn("[VisaResidencyContentGenerator] JSON parse failed: #{e.message.truncate(150)}")
      nil
    end
  end
end
