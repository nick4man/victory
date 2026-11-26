# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatPageContextHelper, type: :helper do
  describe '#chat_page_context' do
    it 'рендерит script-тег application/json с id chat-page-context' do
      html = helper.chat_page_context(kind: 'property', slug: 'dom-1')

      expect(html).to include('<script type="application/json" id="chat-page-context">')
      expect(html).to include('"kind":"property"')
      expect(html).to include('"slug":"dom-1"')
      expect(html).to end_with('</script>')
    end

    it '</script> в значении не ломает разметку и JSON парсится обратно' do
      html = helper.chat_page_context(kind: 'property', slug: 'x</script><script>alert(1)</script>')

      # ActiveSupport to_json экранирует < > как < >: literal "</script>"
      # внутри значения отсутствует, тег ровно один открытый и один закрытый.
      expect(html).not_to include('x</script>')
      expect(html.scan('<script').size).to eq(1)
      expect(html.scan('</script>').size).to eq(1)

      json = html[/>(.*)<\/script>/m, 1]
      expect(JSON.parse(json)['slug']).to eq('x</script><script>alert(1)</script>')
    end

    it 'произвольный </ в значении не даёт literal </ в разметке' do
      html = helper.chat_page_context(kind: 'landing', district: 'a</b')
      expect(html).not_to include('a</b')
      expect(JSON.parse(html[/>(.*)<\/script>/m, 1])['district']).to eq('a</b')
    end

    it 'nil и пустой хеш — nil' do
      expect(helper.chat_page_context(nil)).to be_nil
      expect(helper.chat_page_context({})).to be_nil
    end

    it 'nil-значения вырезаются из JSON' do
      html = helper.chat_page_context(kind: 'landing', deal: 'sale', district: nil)
      expect(html).to include('"deal":"sale"')
      expect(html).not_to include('district')
    end
  end
end
