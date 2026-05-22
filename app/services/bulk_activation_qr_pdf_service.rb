# frozen_string_literal: true

require 'prawn'
require 'rqrcode'

# #413f Шаг 3 (bulk activation) — генерирует PDF с одной страницей на
# каждого phone-only клиента: имя + QR (t.me/anvictorybot?start=<token>) +
# URL текстом. Агентство печатает листы и раскладывает в офисе / кладёт
# в договоры → клиент сканирует → попадает в бота → ActivationRequestProcessor
# matches phone → активируется.
#
# Generates fresh `TgLinkToken` per user inside transaction. Side-effect
# accepted (token persists в БД, valid 30 min). Если PDF не использован
# до expires_at — токены auto-invalidate, regeneration через повторный run.
#
# Output: Prawn-rendered binary string (caller сам сохраняет на disk).
#
# DLP: phone shown masked как `+7•••2345` — последние 4 цифры (договоры
# часто видят сторонние люди в офисе/типографии).
class BulkActivationQrPdfService
  PAGE_MARGIN    = 40
  QR_SIZE        = 280 # pt — ~ 10cm at 72dpi (хорошо сканируется камерой)
  FONT_PATH      = Rails.root.join('app/assets/fonts/DejaVuSans.ttf').to_s
  FONT_BOLD_PATH = Rails.root.join('app/assets/fonts/DejaVuSans-Bold.ttf').to_s
  FONT_FAMILY    = 'DejaVu'

  def self.call(users:, bot_username: nil)
    new(users, bot_username).call
  end

  def initialize(users, bot_username = nil)
    @users = users
    @bot_username = (bot_username || ENV.fetch('TELEGRAM_BOT_USERNAME', 'anvictorybot')).downcase
    @app_url = ENV.fetch('APP_URL', 'https://victory62.org')
    @generated_count = 0
  end

  def call
    pdf = Prawn::Document.new(page_size: 'A4', margin: PAGE_MARGIN)
    pdf.font_families.update(FONT_FAMILY => { normal: FONT_PATH, bold: FONT_BOLD_PATH })
    pdf.font(FONT_FAMILY)

    @users.each_with_index do |user, i|
      pdf.start_new_page if i.positive?
      token = TgLinkToken.generate!(user: user, source: 'bulk_pdf')
      @generated_count += 1
      render_page(pdf, user, token)
    end

    pdf.render
  end

  attr_reader :generated_count

  private

  def render_page(pdf, user, token)
    # Header — agency brand
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text 'АН «ВИКТОРИ»', size: 10, character_spacing: 3, color: '666666'
    end
    pdf.move_down 4
    pdf.text 'Активация личного кабинета', size: 20, color: '111111'
    pdf.move_down 16

    # Client identification block
    pdf.stroke_color 'cccccc'
    pdf.stroke_horizontal_rule
    pdf.move_down 12
    pdf.font(FONT_FAMILY, style: :bold) { pdf.text client_full_name(user), size: 14, color: '111111' }
    pdf.move_down 4
    pdf.text "Телефон: #{mask_phone(user.phone)}", size: 10, color: '666666'
    pdf.text "ID клиента: ##{user.id}", size: 10, color: '666666'
    pdf.move_down 24

    # QR code centered
    url = "https://t.me/#{@bot_username}?start=#{token.token}"
    qr_png = generate_qr_png(url)
    Tempfile.create(['qr', '.png']) do |f|
      f.binmode
      f.write(qr_png)
      f.flush
      qr_x = (pdf.bounds.width - QR_SIZE) / 2
      pdf.image f.path, at: [qr_x, pdf.cursor], width: QR_SIZE, height: QR_SIZE
    end
    pdf.move_down QR_SIZE + 16

    # URL as fallback (если QR scanner fails)
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text 'Или открыть ссылку:', size: 9, color: '666666', align: :center
    end
    pdf.text url, size: 10, color: '0066cc', align: :center
    pdf.move_down 24

    # Instructions
    pdf.stroke_horizontal_rule
    pdf.move_down 16
    pdf.font(FONT_FAMILY, style: :bold) do
      pdf.text 'Как активировать (30 секунд):', size: 11, color: '111111'
    end
    pdf.move_down 8
    steps = [
      '1.  Откройте Telegram на телефоне',
      '2.  Сканируйте QR-код камерой ИЛИ перейдите по ссылке выше',
      "3.  Нажмите кнопку Start в боте @#{@bot_username}",
      '4.  Поделитесь номером телефона по запросу бота',
      '5.  Вы получите ссылку на личный кабинет в чате'
    ]
    steps.each do |line|
      pdf.text line, size: 10, color: '333333', leading: 2
      pdf.move_down 2
    end
    pdf.move_down 20

    # Footer warning — без italic т.к. DejaVu зарегистрирован только
    # normal+bold. Размер + muted цвет компенсируют визуальный hierarchy.
    pdf.font(FONT_FAMILY) do
      pdf.text "Ссылка действует до #{token.expires_at.strftime('%d.%m.%y %H:%M')} МСК. " \
               'Использовать можно один раз. После активации все уведомления о сделках, ' \
               'документах и событиях будут приходить в Telegram — бесплатно, без SMS.',
               size: 8, color: '999999', align: :center
    end
  end

  def client_full_name(user)
    name = [user.first_name, user.last_name].compact_blank.join(' ').strip
    name.presence || "Клиент ##{user.id}"
  end

  # DLP: показываем только last 4 цифр phone. Печатные листы видят
  # сторонние (типография/доставщик/клиент в офисе).
  def mask_phone(phone)
    digits = phone.to_s.gsub(/\D/, '')
    return '+7 ••• •••• ••••' if digits.length < 4
    "+7 ••• ••• #{digits.last(4)}"
  end

  # RQRCode 2.x → ChunkyPNG image. `to_blob` возвращает binary string
  # (PNG bytes) — это формат подходящий для Prawn `pdf.image`.
  def generate_qr_png(url)
    qr = RQRCode::QRCode.new(url, level: :m)
    qr.as_png(size: 600, border_modules: 2).to_blob
  end
end
