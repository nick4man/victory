# frozen_string_literal: true

# Разовый перенос уже угаданных связей в явную колонку (09.08.26).
#
# До этой миграции соответствие сотрудник ↔ телеграм вычислялось на лету
# совпадением email. Здесь то же совпадение выполняется один раз и
# фиксируется — дальше связь живёт явно и меняется только подтверждением
# директора.
#
# Сравнение регистронезависимое: на проде в TG заведён `Oks07@yandex.ru`, и
# точное сравнение уже подводило. Регистр — не повод считать людей разными.
#
# Связываем только однозначные пары. Если на один email приходится больше
# одной записи с любой из сторон, пропускаем: угадать, кто из двух настоящий,
# нельзя, а неверная связь тише и опаснее отсутствующей — уведомления уйдут
# не тому человеку и никто этого не заметит.
class BackfillUserTelegramLinksByEmail < ActiveRecord::Migration[7.1]
  def up
    linked = execute(<<~SQL.squish).cmd_tuples
      UPDATE users u
      SET telegram_user_id = t.id
      FROM telegram_users t
      WHERE u.telegram_user_id IS NULL
        AND u.email IS NOT NULL AND u.email <> ''
        AND t.email IS NOT NULL AND t.email <> ''
        AND LOWER(TRIM(u.email)) = LOWER(TRIM(t.email))
        AND NOT EXISTS (
          SELECT 1 FROM users u2
          WHERE u2.id <> u.id AND LOWER(TRIM(u2.email)) = LOWER(TRIM(u.email))
        )
        AND NOT EXISTS (
          SELECT 1 FROM telegram_users t2
          WHERE t2.id <> t.id AND LOWER(TRIM(t2.email)) = LOWER(TRIM(t.email))
        )
        AND NOT EXISTS (
          SELECT 1 FROM users u3 WHERE u3.telegram_user_id = t.id
        )
    SQL

    say "связано по email: #{linked}"
  end

  # Откат снимает только связи, а не данные: колонка остаётся, записи целы.
  def down
    execute 'UPDATE users SET telegram_user_id = NULL'
  end
end
