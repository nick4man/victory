# Восстановление из бэкапа — runbook (09.08.26)

> Что делать, когда данные потеряны. Команды точные, выполнять сверху вниз.
> Устройство системы: `docs/superpowers/specs/2026-08-09-backups-design.md`.

## Сначала — не навреди

**Не восстанавливайте, пока не проверили копию.** Проверка не трогает прод:

```bash
bin/backup verify
```

Она поднимает одноразовый PostgreSQL, восстанавливает в него последний дамп,
сверяет расширения и количество строк, затем гасит контейнер. Если проверка не
прошла — берите копию постарше (`bin/backup restore` без аргументов покажет
список) и проверяйте её.

## Сценарий 1. Данные потеряны, контейнеры живы

Ошибочный `DELETE`, неудачная миграция, порча таблицы.

```bash
# 1. Посмотреть, что есть
bin/backup restore

# 2. Убедиться, что нужная копия целая
bin/backup verify

# 3. Восстановить (спросит имя базы для подтверждения)
bin/backup restore /var/backups/victory/db/viktory-<дата>.dump.gpg

# 4. Перезапустить приложение
/usr/bin/docker restart victory-web-1 victory-sidekiq-1

# 5. Убедиться, что сайт отвечает
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/
```

Перед перезаписью скрипт сам делает страховочный дамп текущего состояния — если
восстановили не ту копию, откатиться будет куда.

## Сценарий 2. Потеряли CT 122 целиком

Порядок важен: секреты нужны раньше, чем приложение попытается стартовать.

```bash
# 1. На новой машине: docker, git, gpg, rsync, rclone
sudo apt-get update && sudo apt-get install -y docker.io git gnupg rsync rclone

# 2. Достать копии из offsite (пароль crypt — тот же, что PASSPHRASE_FILE)
rclone config          # завести victory-s3 и victory-crypt заново
rclone copy victory-crypt:victory-backups/db      /var/backups/victory/db
rclone copy victory-crypt:victory-backups/secrets /var/backups/victory/secrets
rclone copy victory-crypt:victory-backups/storage /home/q/victory/storage

# 3. Код
git clone https://github.com/nick4man/victory.git /home/q/victory
cd /home/q/victory

# 4. Секреты — из последнего архива
gpg --batch --decrypt --passphrase-file /etc/victory-backup/passphrase \
    "$(ls -t /var/backups/victory/secrets/*.tar.gpg | head -1)" \
  | tar -C /home/q/victory -xf -

# 5. Поднять БД и redis, дождаться готовности
/usr/bin/docker compose up -d db redis

# 6. Создать базу и восстановить
/usr/bin/docker exec victory-db-1 createdb -U postgres viktory_realty_development
gpg --batch --decrypt --passphrase-file /etc/victory-backup/passphrase \
    "$(ls -t /var/backups/victory/db/*.dump.gpg | head -1)" \
  | /usr/bin/docker exec -i victory-db-1 \
      pg_restore -U postgres -d viktory_realty_development --no-owner --no-acl

# 7. Поднять приложение
/usr/bin/docker compose up -d

# 8. Проверить
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/
```

Отдельно проверьте, что `storage/` на месте — без него каталог откроется, но
без фотографий:

```bash
find /home/q/victory/storage -type f | wc -l    # ожидается порядка 21 000
```

## Пароль шифрования

Лежит в `/etc/victory-backup/passphrase` на боевой машине. **Копия обязана
храниться вне сервера** — в менеджере паролей или на бумаге.

Без пароля ни один бэкап расшифровать нельзя: ни локальный, ни offsite. Это не
починить никакими средствами — данные будут потеряны безвозвратно. Если копии
пароля вне сервера нет, сделайте её прямо сейчас:

```bash
cat /etc/victory-backup/passphrase
```

## Как убедиться, что бэкапы живы

```bash
bin/backup status                                    # что есть и когда сделано
systemctl list-timers 'victory-backup-*' --no-pager  # когда следующий запуск
tail -30 /var/backups/victory/logs/daily.log         # как прошёл последний
```

Раз в неделю в Telegram приходит сводка с зелёным кружком. **Её отсутствие —
повод разбираться:** сводка при успехе существует именно для того, чтобы молчание
не путали с исправной работой.

Красное сообщение приходит немедленно при любом провале.

## Что проверено вручную

| Когда | Что | Результат |
|---|---|---|
| 09.08.26 | `verify` на живом дампе | расширения на месте; properties 117/117, users 23/23, inquiries 51/51, conversations 32/32, property_valuations 8/8 |
| 09.08.26 | `verify` на намеренно битом дампе | код возврата 1, внятная ошибка — проверка умеет проваливаться |
| 09.08.26 | `restore` с неверным подтверждением | отказ, боевая база не тронута (117 объектов на месте) |
| 09.08.26 | прогон при недоступном контейнере БД | ошибка, уведомление в Telegram, ненулевой код |
| 09.08.26 | доставка в Telegram | `ok:true`, сообщение в чате |
| 09.08.26 | побайтовое сравнение 12 файлов из снапшота `storage` | расхождений нет |

Полное восстановление по сценарию 2 на чистой машине **не прогонялось** —
проверены его составные части, но не последовательность целиком. Это стоит
сделать при ближайшей возможности и дописать результат сюда.
