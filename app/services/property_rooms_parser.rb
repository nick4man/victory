# frozen_string_literal: true

# #1 Tier 2.3 — parse `rooms` count из freeform Russian description.
#
# Use-case: Topnlab иногда отдаёт rooms=nil даже когда description явно
# говорит «3-комнатная». Parser извлекает hint из текста как fallback
# для property_mapper.
#
# Patterns purposefully ordered (longest first wins):
#   - «5-комнатная квартира», «5-комн.», «5 комнат»  →  5
#   - «трёхкомнатная», «трехкомнатная»  →  3
#   - «двухкомнатная», «двух-комн»  →  2
#   - «однокомнатная»  →  1
#   - «студия», «свободная планировка»  →  0 (studio convention)
#
# Не лезет в room count > 6 (false-positive matches е.g. «5-литровая»).
# Не trying to parse address numbers (е.g. «д. 23» ≠ rooms).
class PropertyRoomsParser
  WORD_FORMS = {
    'студи' => 0,                # «студия», «студийная»
    'свободн' => 0,              # «свободная планировка»
    'однокомн' => 1, 'одно-комн' => 1,
    'двухкомн' => 2, 'двух-комн' => 2,
    'трёхкомн' => 3, 'трех-комн' => 3, 'трехкомн' => 3,
    'четырёхкомн' => 4, 'четырех-комн' => 4, 'четырехкомн' => 4,
    'пятикомн' => 5,
    'шестикомн' => 6
  }.freeze

  # «N-комн.» / «N комн.» / «N-к» / «N комнат» — N digit пред «комн».
  # Bound: \D before (не «д. 23-комн» где 23 = house). Cap N=1..6.
  NUMERIC_PATTERN = /(?<![\d])([1-6])[\s.-]?(?:комн|к(?=\b|[\s.,]))/i.freeze

  def self.parse(description)
    return nil if description.blank?
    text = description.to_s.downcase

    # 1. Word-forms (longest match wins because we iterate WORD_FORMS order)
    WORD_FORMS.each do |needle, count|
      return count if text.include?(needle)
    end

    # 2. Numeric: «3-комн», «2 к», «4 комнат»
    match = text.match(NUMERIC_PATTERN)
    return match[1].to_i if match

    nil
  end
end
