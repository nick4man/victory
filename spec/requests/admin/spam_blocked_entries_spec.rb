# frozen_string_literal: true

require 'rails_helper'

# JSON-эндпоинты ручной модерации антиспам-блок-листа (issue #219).
# Токен-гейт — AdminTokenAuth (?token=...); POST/DELETE с токеном идут
# без CSRF (ops-скрипты, как у вебхуков), cookie-сессия — через форму.
RSpec.describe 'Admin::SpamBlockedEntries', type: :request do
  include_context 'с админ-токеном'

  describe 'доступ' do
    it 'без токена уводит на форму входа' do
      get admin_spam_blocked_entries_path

      expect(response).to have_http_status(:found)
      expect(response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
    end

    it 'без токена POST не создаёт запись' do
      expect { post admin_spam_blocked_entries_path, params: { url: 'evil.example' } }
        .not_to change(SpamBlockedEntry, :count)
    end

    it 'с токеном пускает' do
      admin_get admin_spam_blocked_entries_path

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['ok']).to be(true)
    end
  end

  describe 'POST /admin/spam_blocked_entries' do
    it 'создаёт local blocked-запись по сырому URL' do
      admin_post admin_spam_blocked_entries_path, params: { url: 'http://www.botmasterru.com/product52284/' }

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body['ok']).to be(true)
      expect(body['entry']['value']).to eq('botmasterru.com/product52284')
      expect(body['entry']['source']).to eq('local')
      expect(body['entry']['status']).to eq('blocked')
    end

    it 'status=suspect кладёт домен в карантин' do
      admin_post admin_spam_blocked_entries_path, params: { url: 'watch.example', status: 'suspect' }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['entry']['status']).to eq('suspect')
    end

    it 'мусорный URL → 422 без записи' do
      expect do
        admin_post admin_spam_blocked_entries_path, params: { url: 'not a url' }
      end.not_to change(SpamBlockedEntry, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_url')
    end

    it 'невалидный статус → 422' do
      admin_post admin_spam_blocked_entries_path, params: { url: 'evil.example', status: 'nope' }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_status')
    end

    it 'помеченный URL реально режется фильтром до LLM' do
      admin_post admin_spam_blocked_entries_path, params: { url: 'moderated.example/landing' }

      result = Llm::SpamFilter.classify('смотрите moderated.example/landing — выгодно',
                                        ip: '198.51.100.10', visitor_token: 'v-1')

      expect(result[:action]).to eq(:drop)
      expect(result[:reason]).to eq(:spam_link)
    end
  end

  describe 'GET /admin/spam_blocked_entries' do
    it 'фильтрует по source/status/entry_type' do
      SpamBlockedEntry.create!(entry_type: :domain, value: 'a-spam.example', status: :blocked, source: 'local')
      SpamBlockedEntry.create!(entry_type: :domain, value: 'b-spam.example', status: :blocked, source: 'hagezi_tif')

      admin_get admin_spam_blocked_entries_path, params: { source: 'local' }

      values = response.parsed_body['entries'].map { |e| e['value'] }
      expect(values).to include('a-spam.example')
      expect(values).not_to include('b-spam.example')
    end

    it 'limit не выше 500' do
      admin_get admin_spam_blocked_entries_path, params: { limit: 10_000 }

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'DELETE /admin/spam_blocked_entries/:id' do
    it 'soft-delete разблокировки: запись скрывается из default scope' do
      entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'forgive.example',
                                       status: :blocked, source: 'local')

      delete admin_spam_blocked_entry_path(entry), params: { token: AdminAuthHelpers::ADMIN_TEST_TOKEN }

      expect(response).to have_http_status(:ok)
      expect(SpamBlockedEntry.find_by(value: 'forgive.example')).to be_nil
      expect(entry.reload.deleted_at).to be_present
    end

    it 'разблокированный домен проходит фильтр' do
      entry = SpamBlockedEntry.create!(entry_type: :domain, value: 'forgive.example',
                                       status: :blocked, source: 'local')

      delete admin_spam_blocked_entry_path(entry), params: { token: AdminAuthHelpers::ADMIN_TEST_TOKEN }

      result = Llm::SpamFilter.classify('что скажете про forgive.example?',
                                        ip: '198.51.100.10', visitor_token: 'v-1')
      expect(result[:action]).to eq(:pass)
    end
  end
end
