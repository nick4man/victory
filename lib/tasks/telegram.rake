# frozen_string_literal: true

namespace :telegram do
  desc 'Sanity check: who am I?'
  task get_me: :environment do
    puts JSON.pretty_generate(Telegram::Client.new.get_me)
  end

  desc 'Set webhook to https://APP_HOST/webhooks/telegram'
  task set_webhook: :environment do
    host = ENV['APP_HOST'].presence or abort('APP_HOST not set')
    url  = "https://#{host}/webhooks/telegram"
    result = Telegram::Client.new.set_webhook(url)
    puts "Set webhook → #{url}"
    puts JSON.pretty_generate(result.is_a?(Hash) ? result : { ok: result })
  end

  desc 'Inspect current webhook'
  task webhook_info: :environment do
    puts JSON.pretty_generate(Telegram::Client.new.webhook_info)
  end

  desc 'Drop the webhook (useful for switching dev/prod)'
  task delete_webhook: :environment do
    Telegram::Client.new.delete_webhook
    puts 'Webhook deleted.'
  end

  desc 'Send a test message to TELEGRAM_STAFF_CHAT_ID'
  task :test_message, [:text] => :environment do |_, args|
    chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].presence or abort('TELEGRAM_STAFF_CHAT_ID not set')
    text = args[:text].presence || "Тест из Rails — #{Time.current.strftime('%H:%M:%S')}"
    result = Telegram::Client.new.send_message(text, chat_id: chat_id)
    puts "Sent message_id=#{result['message_id']} to chat_id=#{result.dig('chat', 'id')}"
  end

  # Phase 14 Iter 58 — sync native /-меню (setMyCommands).
  # Запускать после: deploy с изменением каталога команд, добавлением нового staff,
  # промоут/демоут существующего staff (на случай если реактивный hook не отработал).
  desc 'Sync native TG /-меню: global scopes + per-user (BotCommandScopeChat) для всех staff с dm_chat_id'
  task sync_commands: :environment do
    sync = Telegram::WorkBot::CommandsMenuSync.new
    sync.sync_global!
    puts '[OK] global scopes synced (default + all_group_chats)'

    count = 0
    TelegramUser.where.not(dm_chat_id: nil).find_each do |u|
      sync.sync_for_user!(u)
      count += 1
      puts "[OK] user##{u.id} #{u.display_name.ljust(25)} role=#{u.role} status=#{u.status}"
    rescue StandardError => e
      puts "[FAIL] user##{u.id} #{u.display_name}: #{e.class} #{e.message}"
    end
    puts "Done. #{count} users synced."
  end

  # Phase 15 — backfill /app/inbox/<date>/*.json в telegram_group_messages.
  # InboxSaver сохранял group messages в файлы до того как мы добавили
  # параллельную DB-запись (Phase 15). Эта задача парсит существующие JSON
  # и upsert'ит их в БД для FTS-поиска. Idempotent через unique key.
  #
  # Запуск:
  #   bundle exec rake telegram:backfill_group_messages
  #   bundle exec rake telegram:backfill_group_messages[2026-05-01]  # с даты
  #
  # Метрики: количество parsed / skipped / errors.
  desc 'Backfill /app/inbox/<date>/*.json в telegram_group_messages (Phase 15 FTS)'
  task :backfill_group_messages, [:since_date] => :environment do |_, args|
    inbox_dir = Rails.root.join('inbox')
    unless inbox_dir.directory?
      puts "[WARN] #{inbox_dir} не существует — backfill пропущен."
      next
    end

    since = args[:since_date].presence ? Date.strptime(args[:since_date], '%Y-%m-%d') : nil
    parsed = skipped = errors = 0

    Dir.glob(inbox_dir.join('*.json')).sort.each do |path|
      basename = File.basename(path)

      # filename format: 2026-05-22_18-30-15_id-1003779115845_msg1092.json
      if since && (m = basename.match(/\A(\d{4}-\d{2}-\d{2})_/))
        file_date = Date.strptime(m[1], '%Y-%m-%d') rescue nil
        if file_date && file_date < since
          skipped += 1
          next
        end
      end

      begin
        meta = JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        puts "[ERR] #{basename}: parse #{e.message}"
        errors += 1
        next
      end

      chat = meta['chat'] || {}
      chat_type = chat['type'].to_s
      unless chat_type.in?(%w[group supergroup])
        skipped += 1
        next
      end

      body = meta['text'].to_s.presence || meta['caption'].to_s
      from = meta['from'] || {}
      payload_kind = if meta['photo_meta'] then 'photo'
                     elsif meta['document_meta'] then 'document'
                     else 'text'
                     end

      begin
        TelegramGroupMessage.upsert(
          {
            tg_chat_id: chat['id'].to_i,
            tg_message_id: meta['message_id'].to_i,
            tg_thread_id: meta['message_thread_id'],
            tg_user_id: from['id'],
            sender_username: from['username'],
            sender_first_name: from['first_name'],
            body: body,
            payload_kind: payload_kind,
            has_attachment: meta['photo_meta'].present? || meta['document_meta'].present?,
            reply_to_tg_message_id: nil, # старые JSON не сохраняли reply_to_message_id
            sent_at: meta['date'].present? ? Time.zone.at(meta['date'].to_i) : Time.parse(meta['ingested_at'].to_s),
            created_at: Time.current,
            updated_at: Time.current
          },
          unique_by: %i[tg_chat_id tg_message_id]
        )
        parsed += 1
      rescue StandardError => e
        puts "[ERR] #{basename}: upsert #{e.class} #{e.message}"
        errors += 1
      end

      puts "[#{parsed}] processed" if (parsed % 100).zero? && parsed.positive?
    end

    puts ''
    puts '=== Backfill summary ==='
    puts "  parsed:  #{parsed}"
    puts "  skipped: #{skipped} (non-group или вне диапазона дат)"
    puts "  errors:  #{errors}"
    puts "  total in DB: #{TelegramGroupMessage.count}"
  end

  # Phase 16 — backfill staff_test tagging для existing Inquiry / LeadEvent /
  # PropertyValuation. Detector тот же что в create-callbacks. One-shot run
  # после migration.
  desc 'Phase 16 — backfill staff_test tagging для existing records'
  task backfill_staff_test_tagging: :environment do
    inquiry_tagged = 0
    Inquiry.where(staff_test: false).find_each do |i|
      result = StaffSubmissionDetector.detect(
        email: i.email, phone: i.phone, name: i.name, tg_user_id: i.client_tg_user_id
      )
      if result.staff_test
        i.update_columns(staff_test: true, staff_test_matched_by: result.matched_by) # rubocop:disable Rails/SkipsModelValidations
        inquiry_tagged += 1
      end
    end
    puts "Inquiries tagged staff_test=true: #{inquiry_tagged}"

    pv_tagged = 0
    PropertyValuation.where(staff_test: false).find_each do |v|
      result = StaffSubmissionDetector.detect(
        email: v.email, phone: v.phone, name: v.name, tg_user_id: nil
      )
      if result.staff_test
        v.update_columns(staff_test: true, staff_test_matched_by: result.matched_by) # rubocop:disable Rails/SkipsModelValidations
        pv_tagged += 1
      end
    end
    puts "PropertyValuations tagged staff_test=true: #{pv_tagged}"

    le_tagged = 0
    LeadEvent.where(staff_test: false).find_each do |le|
      meta = le.metadata || {}
      result = StaffSubmissionDetector.detect(
        email: meta['email'], phone: meta['phone'], name: meta['name'], tg_user_id: meta['tg_user_id']
      )
      # Также наследуем от parent Inquiry если есть
      if !result.staff_test && le.lead_ref.is_a?(Inquiry) && le.lead_ref.staff_test
        le.update_columns(staff_test: true, staff_test_matched_by: "inherited_from_inquiry##{le.lead_ref.id}") # rubocop:disable Rails/SkipsModelValidations
        le_tagged += 1
      elsif result.staff_test
        le.update_columns(staff_test: true, staff_test_matched_by: result.matched_by) # rubocop:disable Rails/SkipsModelValidations
        le_tagged += 1
      end
    end
    puts "LeadEvents tagged staff_test=true: #{le_tagged}"

    puts ''
    puts 'Done. KPI snapshot теперь скрывает их по умолчанию (rake kpi:phase_a).'
  end

  # Phase 16.5 — backfill embeddings для TelegramGroupMessage rows которые
  # ещё не embed'нуты (нет embedding_record). Per-enqueue delay уважает
  # Google free tier 100 rpm.
  desc 'Phase 16.5 — backfill semantic embeddings для group messages'
  task :backfill_group_message_embeddings, [:delay] => :environment do |_t, args|
    delay = (args[:delay] || 0.7).to_f.clamp(0.5, 5.0)

    scope = TelegramGroupMessage.where.not(body: [nil, ''])
                                .left_joins(:embedding_record)
                                .where(telegram_group_message_embeddings: { id: nil })
    total = scope.count
    puts "Embedding backfill: #{total} pending (delay=#{delay}s per enqueue)"

    if total.zero?
      puts 'Nothing to do — все relevant messages embedded.'
      next
    end

    scope.find_each do |m|
      EmbedTelegramGroupMessageJob.perform_later(m.id)
      print '.'
      sleep delay
    end

    puts ''
    puts "Enqueued #{total} jobs в :low_priority. Watch:"
    puts '  docker logs --since 5m victory-sidekiq-1 | grep EmbedTelegramGroupMessageJob'
  end

  # Phase 16.6 — backfill embeddings для LeadEvent.
  desc 'Phase 16.6 — backfill semantic embeddings для LeadEvent'
  task :backfill_lead_event_embeddings, [:delay] => :environment do |_t, args|
    delay = (args[:delay] || 0.7).to_f.clamp(0.5, 5.0)

    scope = LeadEvent.left_joins(:embedding_record)
                     .where(lead_event_embeddings: { id: nil })
    total = scope.count
    puts "LeadEvent embedding backfill: #{total} pending (delay=#{delay}s)"

    if total.zero?
      puts 'Nothing to do — все leads embedded.'
      next
    end

    scope.find_each do |le|
      EmbedLeadEventJob.perform_later(le.id)
      print '.'
      sleep delay
    end

    puts ''
    puts "Enqueued #{total} jobs. Verify:"
    puts '  bundle exec rails runner "puts LeadEventEmbedding.count"'
  end
end
