# frozen_string_literal: true

# Operational health диагностика для Topnlab integration. Менеджер
# использует чтобы понять что попросить агентов заполнить в CRM.
#
# Запуск:
#   docker exec victory-web-1 bin/rake topnlab:diagnose:gaps
#   docker exec victory-web-1 bin/rake topnlab:diagnose:per_agent
#
# Output: markdown в STDOUT (для копи-паста в TG/email).
namespace :topnlab do
  namespace :diagnose do
    desc 'Show data-quality gaps в Topnlab-imported properties (markdown report)'
    task gaps: :environment do
      base = Property.unscoped.where(external_source: 'topnlab')
      total = base.count
      on_site = Property.in_advertising.count

      gaps = {
        'Нет владельца (owner_user_id)' => base.where(owner_user_id: nil).count,
        'NULL rooms (нет данных или free-planning)' => base.where(rooms: nil).count,
        'Описание < 50 символов'                    => base.where('description IS NULL OR LENGTH(description) < 50').count,
        'Нет фотографий'                            => base.left_joins(images_attachments: :blob).where('active_storage_attachments.id IS NULL').distinct.count,
        'deal_state=ad но in_mls=false'             => base.where(deal_state: 'ad', in_mls: [false, nil]).count
      }

      pct = ->(n) { total.zero? ? 0 : ((n.to_f / total) * 100).round(1) }
      bar = ->(p) { fill = (p / 5).round.clamp(0, 20); '█' * fill + '░' * (20 - fill) }

      puts "## Topnlab data-quality gaps — #{Date.current.strftime('%d.%m.%y')}"
      puts ''
      puts "Total Topnlab properties: **#{total}** · On-site (advertising): **#{on_site}**"
      puts ''
      puts '| Gap | Count | % | |'
      puts '|---|---:|---:|---|'
      gaps.each do |label, count|
        p_value = pct.call(count)
        puts "| #{label} | #{count} | #{p_value}% | `#{bar.call(p_value)}` |"
      end
      puts ''

      # Client cabinet activation
      invited = User.where.not(invited_at: nil).count
      clients = User.where(role: 0, deleted_at: nil, active: true).count
      puts '### Cabinet activation'
      puts ''
      puts "- Client users: **#{clients}**"
      puts "- Invited to cabinet (invited_at not null): **#{invited}**"
      puts "- Properties с linked owner: **#{base.where.not(owner_user_id: nil).count}**"
      puts ''

      # Referrals + partner activity
      referrals_total = Referral.count
      referrals_open = Referral.open.count
      puts '### Referrals (Phase 3)'
      puts ''
      puts "- Total: **#{referrals_total}**, open: **#{referrals_open}**"
      puts "- Closed_won: **#{Referral.closed_won.count}**, closed_lost: **#{Referral.closed_lost.count}**"
      puts "- Partner agencies (active): **#{PartnerAgency.where(status: 'active').count}**"
      puts "- Earned (sum closed_won.final_commission): " \
           "**#{(Referral.closed_won.sum(:final_commission_amount) || 0).to_i} ₽**"
      puts ''

      # Action items
      puts '### 🔧 Action items для менеджера'
      puts ''
      if gaps['Нет владельца (owner_user_id)'].to_i.positive?
        puts "- Попросить агентов привязать seller-клиентов к realty cards в Topnlab " \
             "(`/clients/get-by-entity` сейчас возвращает 0 для всех #{gaps['Нет владельца (owner_user_id)']} объектов). " \
             "Без этого `/cabinet/properties` остаётся пустым."
      end
      if gaps['NULL rooms (нет данных или free-planning)'].to_i.positive?
        puts "- Дозаполнить поле `rooms` в Topnlab для #{gaps['NULL rooms (нет данных или free-planning)']} объектов " \
             '(или мы пометим как free-planning).'
      end
      if gaps['Описание < 50 символов'].to_i.positive?
        puts "- #{gaps['Описание < 50 символов']} объектов без описания (или короткое) — " \
             'попросить агентов написать. Без описания property не публикуется на сайте.'
      end
      if gaps['Нет фотографий'].to_i.positive?
        puts "- #{gaps['Нет фотографий']} объектов без фото — `TopnlabPhotoSyncJob` " \
             'мог упасть. Перезапустить sync или агенты должны загрузить в CRM.'
      end
      puts ''
    end

    desc 'Per-agent breakdown — какой агент имеет больше всего gaps'
    task per_agent: :environment do
      base = Property.unscoped.where(external_source: 'topnlab').includes(:user)

      grouped = base.group_by { |p| p.user&.full_name || '— нет агента —' }

      puts "## Topnlab per-agent gaps — #{Date.current.strftime('%d.%m.%y')}"
      puts ''
      puts '| Агент | Всего | Нет owner | NULL rooms | Нет фото |'
      puts '|---|---:|---:|---:|---:|'

      grouped.sort_by { |_, props| -props.size }.each do |agent, props|
        total = props.size
        no_owner = props.count { |p| p.owner_user_id.nil? }
        null_rooms = props.count { |p| p.rooms.nil? }
        no_images = props.count { |p| !p.images.attached? }
        puts "| #{agent} | #{total} | #{no_owner} | #{null_rooms} | #{no_images} |"
      end
      puts ''
    end
  end
end
