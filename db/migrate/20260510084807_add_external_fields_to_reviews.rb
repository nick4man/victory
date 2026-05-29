# frozen_string_literal: true

# Lets reviews exist without a User: anonymous web form, chat-bot,
# and copy-pasted external reviews (Yandex Maps, 2GIS) all need this.
# Repurposes the existing :source column (was 'web/mobile/email' enum)
# for review platform: 'own' | 'yandex' | '2gis' | 'google' | 'avito' | 'other'.
class AddExternalFieldsToReviews < ActiveRecord::Migration[7.1]
  def change
    change_column_null :reviews, :user_id, true

    # source already exists (string) — switch its default + meaning
    change_column_default :reviews, :source, from: nil, to: 'own'

    add_column :reviews, :external_url,  :string  unless column_exists?(:reviews, :external_url)
    add_column :reviews, :author_name,   :string  unless column_exists?(:reviews, :author_name)
    add_column :reviews, :author_email,  :string  unless column_exists?(:reviews, :author_email)
    add_column :reviews, :author_phone,  :string  unless column_exists?(:reviews, :author_phone)
    add_column :reviews, :submitted_via, :string  unless column_exists?(:reviews, :submitted_via)

    add_index :reviews, :source unless index_exists?(:reviews, :source)
    add_index :reviews, :submitted_via unless index_exists?(:reviews, :submitted_via)
  end
end
