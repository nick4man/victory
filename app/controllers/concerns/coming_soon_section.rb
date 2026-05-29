# frozen_string_literal: true

module ComingSoonSection
  extend ActiveSupport::Concern

  def render_coming_soon(section, description = nil)
    locals = { section: section }
    locals[:description] = description if description
    render template: 'shared/coming_soon', locals: locals
  end
end
