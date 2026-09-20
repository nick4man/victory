# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- второй аргумент describe группирует
# спеку по фиче (мастер помнит своего бота), а не по одному методу.
RSpec.describe Telegram::WorkBot::Wizard::Engine, 'мастер помнит своего бота' do
  include_context 'wizard DM harness'

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  let!(:director) do
    TelegramUser.create!(tg_user_id: 99_301, tg_username: 'oksana', role: 'director', is_manager: true,
                         status: 'active', dm_chat_id: 99_301)
  end
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: director)
  end

  def start_in_test
    Telegram::BotContext.within('test') { tap_callback("wiz:s:task:#{lead.id}", user: director) }
  end

  it 'текст в рабочий бот не отвечает на мастер, начатый в тестовом' do
    start_in_test
    expect(last_text).to include('До какого числа?')

    expect(say('завтра', user: director)).to be_nil
    expect(described_class.active?(director)).to be(false)
    Telegram::BotContext.within('test') { expect(described_class.active?(director)).to be(true) }
  end

  it 'кнопка мастера другого бота — «неактуально», а не продолжение' do
    start_in_test

    press('Завтра', user: director)

    expect(acks.last.first).to include('неактуален')
  end

  it 'новый мастер в другом боте не затирает незаконченный' do
    start_in_test

    tap_callback("wiz:s:task:#{lead.id}", user: director)

    expect(last_text).to include('незаконченный мастер', 'тестовом')
    expect(last_callbacks).to include('wiz:x')
    expect(director.reload.pending_action.dig('data', 'bot')).to eq('test')
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
