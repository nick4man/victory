# frozen_string_literal: true

# Состояние опроса агента о собственнике объекта (10.08.26).
#
# Бот спрашивает агента, кто владелец объекта, потому что этих данных нет ни у
# нас, ни в Topnlab (проверено: `/clients/get-by-entity` отдаёт пустой список по
# всем карточкам). Опрос идёт по одному объекту за раз — у топ-агента их 44, и
# сорок четыре сообщения подряд превратили бы бота в спам, после чего его
# замьютят вместе со всеми остальными уведомлениями.
#
# Поэтому нужно помнить три вещи:
#   • когда спрашивали — чтобы не спросить повторно, пока человек думает;
#   • до какого срока отложено — агент нажал «Отложить»;
#   • когда агент сказал «не мой объект» — дальше это забота директора, а не
#     повод спрашивать снова.
#
# Поля живут на Property, а не в отдельной таблице: это состояние одного
# конкретного объекта, оно одноразовое и умирает вместе с заполнением
# owner_user_id. Отдельная таблица здесь дала бы join ради трёх timestamp'ов.
#
# Синхронизация их не перетирает: `Topnlab::Importer` делает upsert из
# whitelist-хеша маппера, этих ключей в нём нет.
class AddOwnerRequestFieldsToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :owner_request_sent_at, :datetime
    add_column :properties, :owner_request_snoozed_until, :datetime
    add_column :properties, :owner_request_declined_at, :datetime

    # Частичный индекс: джоб выбирает только объекты без собственника, а таких
    # меньшинство и со временем должно стать ноль. Полный индекс по трём
    # колонкам обслуживал бы строки, которые запрос никогда не увидит.
    add_index :properties, %i[owner_request_sent_at owner_request_snoozed_until],
              where: 'owner_user_id IS NULL AND deleted_at IS NULL',
              name: 'index_properties_on_owner_request_pending'
  end
end
