# frozen_string_literal: true

module ChatTools
  # Marker module so Zeitwerk has a top-level ChatTools to nest into.
  # Tools live as siblings (SearchProperties, SemanticSearch, ...) and use
  # ChatTools::Format and ChatTools::Url helpers.
  module Base
  end
end
