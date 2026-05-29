# frozen_string_literal: true

module PropertyDossier
  # A3 — Agent page. Premium-feel personal advisor card:
  # left=avatar (~150x150) + name + role, right=bio + contacts. Под
  # ними — rating + reviews badge + QR на agent profile.
  class AgentPage
    include AuditPdf::Theme::Helpers

    AVATAR_SIZE = 150

    def initialize(doc, property, locale: I18n.locale, rates: nil)
      @doc = doc
      @p = property
      @agent = resolve_agent
      @locale = locale
      @rates = rates
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      hero_block
      bio_block
      contacts_block
      profile_qr
      page_footer
    end

    private

    def paint_paper
      @doc.canvas do
        @doc.fill_color AuditPdf::Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color AuditPdf::Theme::INK
    end

    def page_header
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('dossier.agent.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color AuditPdf::Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 22
    end

    # Avatar (left) + name/role (right of avatar). Fallback к initials-box
    # если avatar нет.
    def hero_block
      y = @doc.cursor

      # Avatar / initials placeholder
      avatar_bytes = avatar_bytes()
      if avatar_bytes
        begin
          @doc.image StringIO.new(avatar_bytes),
                     at: [0, y],
                     width: AVATAR_SIZE,
                     height: AVATAR_SIZE,
                     position: :center,
                     vposition: :center
        rescue StandardError => e
          Rails.logger.warn("[PropertyDossier::AgentPage] avatar embed failed: #{e.class}")
          render_initials_placeholder(y)
        end
      else
        render_initials_placeholder(y)
      end

      # Name + role to the right of avatar
      text_x = AVATAR_SIZE + 24
      @doc.bounding_box([text_x, y], width: @doc.bounds.width - text_x, height: AVATAR_SIZE) do
        @doc.fill_color AuditPdf::Theme::INK
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
          @doc.text agent_full_name, size: 20
        end
        @doc.move_down 6
        @doc.fill_color AuditPdf::Theme::MUTED
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
          @doc.text I18n.t('dossier.agent.role_default'), size: 11
        end
        @doc.fill_color AuditPdf::Theme::INK
        @doc.move_down 12
        rating_line
      end

      @doc.move_cursor_to(y - AVATAR_SIZE - 30)
    end

    def render_initials_placeholder(y)
      @doc.fill_color AuditPdf::Theme::TINT
      @doc.fill_rectangle [0, y], AVATAR_SIZE, AVATAR_SIZE
      @doc.fill_color AuditPdf::Theme::INK_SOFT
      initials = if @agent
                   "#{@agent.first_name.to_s[0]}#{@agent.last_name.to_s[0]}".upcase
                 else
                   'АН'
                 end
      @doc.bounding_box([0, y - AVATAR_SIZE / 2 + 15], width: AVATAR_SIZE, height: 30) do
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
          @doc.text initials, size: 36, align: :center
        end
      end
      @doc.fill_color AuditPdf::Theme::INK
    end

    def rating_line
      return unless @agent

      rating = (@agent.respond_to?(:agent_average_rating) ? @agent.agent_average_rating : nil)
      reviews = (@agent.respond_to?(:agent_review_count) ? @agent.agent_review_count : 0).to_i
      return if rating.blank? || rating.to_f.zero? || reviews.zero?

      @doc.fill_color AuditPdf::Theme::INK
      stars = '★' * rating.to_f.round.clamp(0, 5)
      empty = '☆' * (5 - rating.to_f.round.clamp(0, 5))
      @doc.text "#{stars}#{empty}  #{rating.to_f.round(1)}  ·  #{reviews} #{I18n.t('dossier.agent.reviews_label')}",
                size: 10
    end

    def bio_block
      bio = @agent&.try(:bio).to_s.strip
      section_label(I18n.t('dossier.agent.bio_header'))
      @doc.move_down 6
      @doc.fill_color AuditPdf::Theme::INK_SOFT
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
        @doc.text(bio.empty? ? I18n.t('dossier.agent.no_bio') : bio.truncate(800),
                  size: 10.5, leading: 3, align: :justify)
      end
      @doc.fill_color AuditPdf::Theme::INK
      @doc.move_down 18
    end

    def contacts_block
      section_label(I18n.t('dossier.agent.contacts_header'))
      @doc.move_down 6

      phone = @agent&.try(:display_phone).presence || AgencyInfo::PHONE_PRIMARY
      email = @agent&.try(:email).presence || AgencyInfo::EMAIL

      rows = [
        [I18n.t('dossier.agent.phone_label'), phone],
        [I18n.t('dossier.agent.email_label'), email]
      ]

      @doc.table(rows, cell_style: { borders: [:bottom], border_color: AuditPdf::Theme::HAIRLINE,
                                     padding: [7, 0], size: 11 },
                       width: @doc.bounds.width) do
        column(0).text_color = AuditPdf::Theme::INK_SOFT
        column(1).align = :right
        column(1).font_style = :bold
      end
      @doc.move_down 20
    end

    def profile_qr
      return unless @agent && @agent.respond_to?(:agent_slug) && @agent.agent_slug.present?

      url = "#{AgencyInfo::WEBSITE_URL}/agents/#{@agent.agent_slug}"
      png = QrRenderer.png(url)
      return if png.nil?

      qr_size = 80
      x = (@doc.bounds.width - qr_size) / 2.0
      @doc.image StringIO.new(png), at: [x, @doc.cursor], width: qr_size, height: qr_size
      @doc.move_cursor_to(@doc.cursor - qr_size - 8)
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.agent.profile_qr_caption'),
                size: 8, character_spacing: 2, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    rescue StandardError => e
      Rails.logger.warn("[PropertyDossier::AgentPage] QR failed: #{e.class}")
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.page_footer', page: 4, report: report_label),
                size: 7, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    end

    # ---- helpers ----

    # Resolve agent: prefer property.user (listing agent); fallback nil.
    def resolve_agent
      @p.respond_to?(:user) ? @p.user : nil
    rescue StandardError => e
      Rails.logger.warn("[PropertyDossier::AgentPage] resolve_agent failed: #{e.class}")
      nil
    end

    def agent_full_name
      return AgencyInfo::NAME unless @agent

      name = [@agent.try(:first_name), @agent.try(:last_name)].compact.join(' ').strip
      name.presence || AgencyInfo::NAME
    end

    def avatar_bytes
      return nil unless @agent && @agent.respond_to?(:avatar) && @agent.avatar.attached?

      @agent.avatar.blob.download
    rescue StandardError => e
      Rails.logger.warn("[PropertyDossier::AgentPage] avatar download failed: #{e.class}")
      nil
    end

    def report_label
      @p.try(:slug) || "##{@p.id}"
    end
  end
end
