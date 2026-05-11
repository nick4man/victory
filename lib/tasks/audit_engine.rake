# frozen_string_literal: true

# Rake interface for audit-engine sidecar maintenance from the Rails side.
# Engine has its own APScheduler that fires fetch_macro_cbr daily at 06:00 МСК;
# these tasks are escape hatches for manual refresh + deploy-time prep.
namespace :audit_engine do
  desc 'Manual refresh of CB RF macro data (key rate, inflation). Runs engine fetch_macro_cbr.'
  task refresh_macro: :environment do
    cmd = 'docker compose --env-file .env --env-file .env.audit ' \
          '-f docker-compose.yml -f docker-compose.audit.yml ' \
          'exec -T audit-api python -m scripts.fetch_macro_cbr'
    puts "→ #{cmd}"
    system(cmd) || (warn 'Macro refresh failed' && exit(1))
  end

  desc 'Show engine /macro/latest from Rails-side client.'
  task macro_latest: :environment do
    data = AuditEngine::Client.new.macro_latest
    puts JSON.pretty_generate(data)
  rescue AuditEngine::Error => e
    warn "Engine unavailable: #{e.message}"
    exit 1
  end

  desc 'Re-seed engine bank offers (idempotent).'
  task seed_bank_offers: :environment do
    cmd = 'docker compose --env-file .env --env-file .env.audit ' \
          '-f docker-compose.yml -f docker-compose.audit.yml ' \
          'exec -T audit-api python -m scripts.seed_bank_offers'
    puts "→ #{cmd}"
    system(cmd) || (warn 'Bank offers seed failed' && exit(1))
  end
end
