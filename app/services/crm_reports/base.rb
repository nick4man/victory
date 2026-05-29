# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

module CrmReports
  # Base class for Topnlab-callback PDF reports.
  # Subclasses implement `#draw` (writes content into @pdf) and `#default_filename`.
  # `#generate_and_upload!` is called by Webhooks::TopnlabReportsController and
  # returns a public URL for Topnlab to redirect to.
  class Base
    A4_MARGIN = [40, 40, 40, 40].freeze

    attr_reader :ids, :user, :report, :pdf

    def initialize(ids:, user:, report:)
      @ids = Array(ids).map(&:to_i).reject(&:zero?)
      @user = user.is_a?(Hash) ? user : (user&.to_h || {})
      @report = report
      @pdf = Prawn::Document.new(page_size: 'A4', margin: A4_MARGIN)
      setup_fonts
    end

    # Render the PDF, attach to ActiveStorage as a public blob, return service_url.
    def generate_and_upload!
      draw

      data = pdf.render
      blob = ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new(data),
        filename:     default_filename,
        content_type: 'application/pdf'
      )
      blob.url(disposition: 'inline')
    end

    def draw
      raise NotImplementedError, "#{self.class} must implement #draw"
    end

    def default_filename
      "#{report&.slug || 'report'}-#{Time.current.strftime('%Y%m%d-%H%M%S')}.pdf"
    end

    protected

    def setup_fonts
      regular = Rails.root.join('app/assets/fonts/DejaVuSans.ttf')
      bold    = Rails.root.join('app/assets/fonts/DejaVuSans-Bold.ttf')
      return unless File.exist?(regular)

      pdf.font_families.update('DejaVu' => {
        normal: regular.to_s,
        bold:   File.exist?(bold) ? bold.to_s : regular.to_s
      })
      pdf.font 'DejaVu'
    end

    def header(title, subtitle = nil)
      pdf.font_size 18
      pdf.text title
      pdf.move_down 4
      if subtitle
        pdf.font_size 10
        pdf.fill_color '666666'
        pdf.text subtitle
        pdf.fill_color '000000'
      end
      pdf.move_down 16
    end

    def footer(text = nil)
      pdf.repeat(:all) do
        pdf.bounding_box([0, 30], width: pdf.bounds.width, height: 20) do
          pdf.font_size 8
          pdf.fill_color 'aaaaaa'
          pdf.text(text || "АН Виктори · #{Time.current.strftime('%d.%m.%Y')}", align: :center)
          pdf.fill_color '000000'
        end
      end
    end

    def number(value)
      ActionController::Base.helpers.number_with_delimiter(value.to_i, delimiter: ' ')
    end
  end
end
