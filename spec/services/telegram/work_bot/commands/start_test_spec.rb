# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::StartTest do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 500_101, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 500_101)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 500_102, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', status: 'active', dm_chat_id: 500_102)
  end
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  def run(user)
    message = { 'message_id' => 1, 'from' => { 'id' => user.tg_user_id }, 'text' => '/starttest',
                'chat' => { 'id' => user.tg_user_id, 'type' => 'private' } }
    described_class.new(message: message, args: '', tg_user: user, client: tg_client).call
  end

  def stub_list(state)
    stub_request(:get, 'https://api.github.com/user/codespaces')
      .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
                 body: { codespaces: [{ name: 'crm-sandbox-abc', display_name: 'crm-sandbox', state: state,
                                        web_url: 'https://github.com/codespaces/crm-sandbox-abc',
                                        git_status: { ref: 'claude/crm-sandbox-codespace' } }] }.to_json)
  end

  before do
    stub_const('ENV', ENV.to_h.merge('GITHUB_CODESPACE_TOKEN' => 'gh-token'))
    allow(Sandbox::CodespaceReadyJob).to receive(:perform_async)
  end

  it 'спящую песочницу будит и обещает написать, когда встанет' do
    stub_list('Shutdown')
    start = stub_request(:post, 'https://api.github.com/user/codespaces/crm-sandbox-abc/start')
            .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

    run(director)

    expect(start).to have_been_requested
    expect(Sandbox::CodespaceReadyJob).to have_received(:perform_async).with(director.dm_chat_id)
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('Бужу песочницу', '@anvictory_testsbot', 'Что сейчас в песочнице'), anything)
  end

  it 'поднятую песочницу не трогает и сразу зовёт тестировать' do
    stub_list('Available')

    run(director)

    expect(Sandbox::CodespaceReadyJob).not_to have_received(:perform_async)
    expect(tg_client).to have_received(:send_message).with(a_string_including('уже на ходу'), anything)
    expect(a_request(:post, %r{/start})).not_to have_been_made
  end

  it 'подсказки редактору в сводку не попадают, разметка не протекает' do
    stub_list('Available')

    run(director)

    text = nil
    expect(tg_client).to have_received(:send_message) { |body, *| text = body }
    expect(text).to include('Что сейчас в песочнице', '<b>')
    expect(text).not_to include('<!--', 'Этот файл печатает')
  end

  it 'агенту команда недоступна' do
    run(agent)

    expect(a_request(:get, 'https://api.github.com/user/codespaces')).not_to have_been_made
  end

  it 'нет токена — понятный отказ, а не падение' do
    stub_const('ENV', ENV.to_h.merge('GITHUB_CODESPACE_TOKEN' => nil))

    expect(run(director)).to eq(:error)
    expect(tg_client).to have_received(:send_message).with(a_string_including('GITHUB_CODESPACE_TOKEN'), anything)
  end

  it 'GitHub отвечает ошибкой — тоже отказ с текстом' do
    stub_request(:get, 'https://api.github.com/user/codespaces').to_return(status: 401, body: '{}')

    expect(run(director)).to eq(:error)
    expect(tg_client).to have_received(:send_message).with(a_string_including('GitHub ответил 401'), anything)
  end
end
