# frozen_string_literal: true

# Рендерит <script type="application/json" id="chat-page-context"> с
# идентификаторами текущей страницы. Чат-виджет читает его при отправке
# сообщения и передаёт в POST как page.ctx — так бот знает, ЧТО за страница
# у посетителя, а не только её URL. `</` экранируется, чтобы значение не
# могло закрыть script-тег и сломать/инъекцировать разметку.
module ChatPageContextHelper
  def chat_page_context(hash)
    return if hash.blank?

    json = hash.compact.to_json.gsub('</', '<\\/')
    content_tag(:script, json.html_safe, type: 'application/json', id: 'chat-page-context')
  end
end
