# frozen_string_literal: true

require 'spec_helper'
require 'pathname'
require 'yaml'

RSpec.describe '.github/workflows' do
  let(:repo_root) { Pathname.new(__dir__).join('..', '..').expand_path }
  let(:kimi_workflow) { repo_root.join('.github/workflows/kimi.yml') }
  let(:parsed) { YAML.safe_load_file(kimi_workflow, aliases: true) }

  # Регрессия 14.11.26: в PR #238 client_id сервис-аккаунта OpenCode был
  # захардкожен в workflow; GitGuardian классифицировал его как секрет.
  # client_id должен браться из GitHub Secret/Variable, а не лежать в git.
  describe 'kimi.yml' do
    it 'парсится как валидный YAML' do
      expect { parsed }.not_to raise_error
    end

    it 'не содержит захардкоженный client_id OpenCode' do
      content = kimi_workflow.read
      expect(content).not_to match(/client_id=sk_[a-f0-9-]+/)
    end

    it 'использует secrets.OPENCODE_CLIENT_ID для OIDC-обмена' do
      content = kimi_workflow.read
      expect(content).to include('client_id="${{ secrets.OPENCODE_CLIENT_ID }}"')
        .or include("client_id='${{ secrets.OPENCODE_CLIENT_ID }}'")
        .or include('client_id=${{ secrets.OPENCODE_CLIENT_ID }}')
    end
  end
end
