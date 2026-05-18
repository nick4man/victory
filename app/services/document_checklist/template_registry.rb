# frozen_string_literal: true

module DocumentChecklist
  # Phase 4C — Templates каталог: какие документы required per (deal_type
  # × property_type) ИЛИ per inquiry_type для non-property flows.
  #
  # Каждый template = { required: [...], optional: { kind => condition_lambda } }
  # - required: array of kinds → создаются всегда
  # - optional: hash kind → ->(context) { Boolean } — создаются при true
  #
  # Lookup precedence (см. Builder#resolve_template):
  #   1. property_type.slug + deal_type → e.g. 'flat_sale'
  #   2. inquiry_type (если нет property или inquiry-only flow) → 'mortgage'
  #   3. 'default_sale' fallback
  #
  # При добавлении нового template — sync с DocumentRequirement::DEPENDS_ON
  # (cascade auto-triggers prerequisites при received).
  class TemplateRegistry
    # Standard sale flow для квартиры — самый частый case
    APARTMENT_SALE = {
      required: %w[
        passport_main
        passport_registration
        snils
        inn
        egrn_excerpt
        contract_sale
      ],
      optional: {
        # married→ spousal_consent (через metadata.client_marital_status)
        'spousal_consent' => ->(ctx) { ctx[:client_marital_status] == 'married' },
        # has_proxy → power_of_attorney
        'power_of_attorney' => ->(ctx) { ctx[:has_proxy] == true },
        # has_mortgage → mortgage docs cascade
        'mortgage_approval' => ->(ctx) { ctx[:has_mortgage] == true },
        # has_minor_co_owner → birth_certificate + органы опеки
        'birth_certificate' => ->(ctx) { ctx[:has_minor_owner] == true }
      }
    }.freeze

    # Квартира в аренду — гораздо легче, без передачи права собственности
    APARTMENT_RENT = {
      required: %w[
        passport_main
        contract_sale
      ],
      optional: {
        'insurance_policy' => ->(_ctx) { true } # рекомендуем всегда
      }
    }.freeze

    # Дом продаётся — apartment_sale + дополнительные для земельного участка
    HOUSE_SALE = {
      required: APARTMENT_SALE[:required] + %w[cadastral_passport],
      optional: APARTMENT_SALE[:optional]
    }.freeze

    # Земельный участок
    LAND_SALE = {
      required: %w[
        passport_main
        passport_registration
        snils
        inn
        egrn_excerpt
        cadastral_passport
        contract_sale
      ],
      optional: {
        'spousal_consent' => ->(ctx) { ctx[:client_marital_status] == 'married' },
        'power_of_attorney' => ->(ctx) { ctx[:has_proxy] == true }
      }
    }.freeze

    # Коммерческая недвижимость — особые требования (юр-документы)
    COMMERCE_SALE = {
      required: %w[
        passport_main
        passport_registration
        snils
        inn
        egrn_excerpt
        cadastral_passport
        contract_sale
        appraisal_report
      ],
      optional: {
        'power_of_attorney' => ->(_ctx) { true } # юрлицам почти всегда
      }
    }.freeze

    # Комната (доля в квартире) — добавляются согласия совладельцев
    ROOM_SALE = {
      required: APARTMENT_SALE[:required] + %w[spousal_consent],
      optional: APARTMENT_SALE[:optional].except('spousal_consent')
    }.freeze

    # Дом / земля в аренду — редко, минимальный набор
    GENERIC_RENT = {
      required: %w[passport_main contract_sale],
      optional: {}
    }.freeze

    # ====== Inquiry-driven templates (когда нет property) ======

    # Mortgage-консультация — отдельный flow, банковские документы
    MORTGAGE_INQUIRY = {
      required: %w[passport_main passport_registration snils inn mortgage_approval],
      optional: {
        'marital_status' => ->(_ctx) { true },
        'spousal_consent' => ->(ctx) { ctx[:client_marital_status] == 'married' }
      }
    }.freeze

    # Запрос на оценку — только appraisal
    EVALUATION_INQUIRY = {
      required: %w[passport_main egrn_excerpt appraisal_report],
      optional: {}
    }.freeze

    # Default fallback — minimal
    DEFAULT_SALE = {
      required: %w[passport_main egrn_excerpt contract_sale],
      optional: {}
    }.freeze

    # Lookup map. Builder использует resolve_template для resolve key.
    TEMPLATES = {
      'flat_sale'      => APARTMENT_SALE,
      'flat_rent'      => APARTMENT_RENT,
      'flat_daily'     => APARTMENT_RENT,
      'room_sale'      => ROOM_SALE,
      'room_rent'      => APARTMENT_RENT,
      'house_sale'     => HOUSE_SALE,
      'house_rent'     => GENERIC_RENT,
      'land_sale'      => LAND_SALE,
      'land_rent'      => GENERIC_RENT,
      'commerce_sale'  => COMMERCE_SALE,
      'commerce_rent'  => GENERIC_RENT,
      'garage_sale'    => DEFAULT_SALE,
      'garage_rent'    => GENERIC_RENT,
      'mortgage'       => MORTGAGE_INQUIRY,
      'evaluation'     => EVALUATION_INQUIRY,
      'default_sale'   => DEFAULT_SALE
    }.freeze

    # @param key [String] e.g. 'flat_sale' или 'mortgage'
    # @return [Hash] {required:, optional:}
    def self.lookup(key)
      TEMPLATES[key.to_s] || DEFAULT_SALE
    end

    def self.keys
      TEMPLATES.keys
    end
  end
end
