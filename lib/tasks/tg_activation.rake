# frozen_string_literal: true

# #413f Шаг 3 — bulk TG activation для phone-only клиентов Topnlab.
#
# Активирует #413 инфраструктуру сразу для всех существующих 100+
# клиентов БЕЗ единого SMS. Output — печатный PDF (1 страница на клиента
# с QR-кодом), агентство печатает и раскладывает в офисе.
#
# Usage:
#   bundle exec rake tg:activation:bulk_generate
#     → /tmp/tg-activation-qrs-YYYYMMDD-HHMM.pdf + STDOUT summary
#
#   bundle exec rake tg:activation:bulk_generate[50]
#     → limit к 50 (для test/dry runs)
#
#   bundle exec rake tg:activation:list
#     → STDOUT: candidates count + первые 20 имён (без token generation)
namespace :tg do
  namespace :activation do
    desc 'Сгенерировать PDF активационных QR для всех phone-only клиентов Topnlab'
    task :bulk_generate, [:limit] => :environment do |_t, args|
      limit = args[:limit]&.to_i || 1000
      users = candidate_users.limit(limit).to_a

      if users.empty?
        puts '⚠️  Нет phone-only клиентов без TG-привязки. Бэклог пуст.'
        exit 0
      end

      puts "📋 Генерирую активационные QR для #{users.size} клиентов..."
      puts '   (создаём по одному TgLinkToken на клиента, валидны 30 минут после генерации)'

      pdf_data = BulkActivationQrPdfService.call(users: users)
      out_path = Rails.root.join('tmp', "tg-activation-qrs-#{Time.current.strftime('%Y%m%d-%H%M')}.pdf")
      File.binwrite(out_path, pdf_data)

      puts ''
      puts "✅ Готово."
      puts "   PDF: #{out_path}"
      puts "   Размер: #{(File.size(out_path) / 1024.0).round(1)} KB"
      puts "   Клиентов: #{users.size}"
      puts ''
      puts '   Следующий шаг: распечатать листы, разложить в офисе/договорах.'
      puts '   Клиенты сканируют QR → попадают в @anvictorybot → подтверждают phone → активированы.'
      puts ''
      puts '   ⏰ ВАЖНО: токены действуют 30 минут после генерации.'
      puts '   Печатайте сразу после run. Если задержка >24ч — перегенерируйте через повторный rake.'
    end

    desc 'Показать кандидатов для bulk_generate без token generation (dry-run)'
    task list: :environment do
      users = candidate_users.to_a
      puts "📋 Кандидатов для TG-активации: #{users.size}"
      puts ''
      if users.empty?
        puts '   Все phone-only клиенты уже активированы или приглашены.'
        exit 0
      end
      puts '   Top 20:'
      users.first(20).each do |u|
        name = [u.first_name, u.last_name].compact_blank.join(' ').strip
        puts "   #{u.id.to_s.rjust(5)}  #{name.ljust(30)}  phone=***#{u.phone.to_s.gsub(/\D/, '').last(4)}"
      end
      puts ''
      puts "   Запусти: rake tg:activation:bulk_generate"
      puts "   Для лимита: rake tg:activation:bulk_generate[N]"
    end

    # Кандидаты — phone-only клиенты, не привязаны к TG, активны, не в stop-list.
    # role=:client отсеивает agents/admins. invited_at не проверяем — может
    # быть set ранее через email-mailer но клиент не активировал TG.
    def candidate_users
      blocked_last10 = PhoneStopList.active.pluck(:phone_last10)
      scope = User.unscoped
                  .where(role: :client, deleted_at: nil, active: true)
                  .where.not(phone: nil)
                  .where(tg_user_id: nil)
                  .order(:id)
      return scope if blocked_last10.empty?

      # Phone в DB как `+7XXXXXXXXXX`, normalize в `9009694844`-формат
      # через regex для compare. SQL-side filter эффективнее чем pluck.
      conds = blocked_last10.map { 'phone NOT LIKE ?' }.join(' AND ')
      binds = blocked_last10.map { |last10| "%#{last10}" }
      scope.where(conds, *binds)
    end
  end
end
