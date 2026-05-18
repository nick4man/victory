# frozen_string_literal: true

# Phase 3 MLS/YRL — seed initial PartnerAgency rows.
#
# Idempotent: find_or_create_by(slug). Existing rows не перезаписываются
# (manually filled contact info, commission rates сохраняются).
#
# Запуск:
#   docker exec victory-web-1 bin/rake partners:seed
namespace :partners do
  desc 'Seed initial PartnerAgency rows для Рязанского рынка'
  task seed: :environment do
    puts "=== Partner agencies seed ===\n"

    seeds = [
      {
        slug: 'cian_961',
        name: 'ЦАН Рязань (Центральное АН)',
        feed_source_key: 'cian_961',
        contact_phone: '+7 (4912) 96-19-61',                 # public
        default_commission_rate: 0.30,                        # 30% standard referral
        settlement_terms: 'Net 14 после закрытия сделки',
        status: 'active',
        notes: 'Подключены через agency_sitemap (Bitrix-based Schema.org JSON-LD). ' \
               'Связь через https://961-961.ru'
      },
      {
        slug: 'novoselye',
        name: 'Новоселье',
        feed_source_key: 'novoselye',
        default_commission_rate: 0.30,
        status: 'inactive',
        notes: 'Placeholder — feed/sitemap not yet integrated. Activate when' \
               ' partnership signed.'
      },
      {
        slug: 'agent62',
        name: 'Агент 62',
        feed_source_key: 'agent62',
        default_commission_rate: 0.30,
        status: 'inactive',
        notes: 'Placeholder для future expansion.'
      },
      {
        slug: 'lr62',
        name: 'Личный Риэлтор 62',
        feed_source_key: 'lr62',
        default_commission_rate: 0.30,
        status: 'inactive',
        notes: 'Placeholder для future expansion.'
      },
      {
        slug: 'cian_aggregator',
        name: 'Cian (агрегатор)',
        feed_source_key: 'cian',                              # matches ExternalListing.source='cian'
        default_commission_rate: nil,                         # manual review per case
        status: 'inactive',                                   # disabled: листинги от разных продавцов
        notes: 'Cian — это аггрегатор, не агентство. Каждый listing OF different ' \
               'seller. Auto-create referral skipped (claimable? = false), manual ' \
               'routing required per inquiry. Когда identifier seller — найден ' \
               'отдельной agency, передавать туда.'
      }
    ]

    created = updated = skipped = 0
    seeds.each do |attrs|
      agency = PartnerAgency.find_by(slug: attrs[:slug])
      if agency
        # Update only attributes that haven't been manually edited.
        # If user уже set contact_email/phone — не перетираем.
        changed = false
        %i[name feed_source_key default_commission_rate settlement_terms status notes].each do |field|
          next if agency[field].present? && agency[field] != attrs[field] && field != :status
          if agency[field] != attrs[field]
            agency[field] = attrs[field]
            changed = true
          end
        end
        if changed
          agency.save!
          updated += 1
          puts "  ✎ updated #{agency.slug}"
        else
          skipped += 1
        end
      else
        agency = PartnerAgency.create!(attrs)
        created += 1
        puts "  ✓ created #{agency.slug} (id=#{agency.id})"
      end
    end

    puts "\n=== DONE: created=#{created}, updated=#{updated}, unchanged=#{skipped} ==="
    puts "Total active partners: #{PartnerAgency.active.count}"
  end
end
