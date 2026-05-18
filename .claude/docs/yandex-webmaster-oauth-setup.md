# Я.Вебмастер OAuth — настройка токена

Инструкция как получить **OAuth-токен** для Yandex.Webmaster API v4, чтобы автоматически вытаскивать индекс-статистику, top-queries, ошибки crawl'а напрямую в KPI cache + dashboard.

Token «вечный» (не expires до явного отзыва), один раз получил — везде используешь.

---

## Шаг 1. Создать OAuth-приложение (5 минут, один раз)

1. Открыть https://oauth.yandex.ru/client/new (нужен логин в Я.Аккаунт — тот же что у Я.Вебмастера).

2. Заполнить форму:

   | Поле | Значение |
   |---|---|
   | **Название сервиса** | `victory62-kpi-fetcher` (любое, видно только тебе) |
   | **Иконка** | optional |
   | **Платформы** | ☑ **«Веб-сервисы»** (только эта) |
   | **Redirect URI** | `https://oauth.yandex.ru/verification_code` (служебный URL Яндекса) |
   | **Доступы** (Permissions) | См. блок ниже |

3. **Доступы (Permissions)** — найди и отметь в разделе «Яндекс.Вебмастер»:

   - ☑ **Получение информации о добавленных пользователем сайтах** (`webmaster:hosts:info`)
   - ☑ **Проверка прав на сайт** (`webmaster:hosts:verify`)
   - ☑ **Чтение настроек и статистики** — обычно один общий toggle «Доступ к Я.Вебмастеру»

   Сomprehensive permissions string: `webmaster:hosts:info,webmaster:hosts:verify,webmaster:hosts:write`

4. Нажать **«Создать приложение»**.

5. На странице созданного приложения скопировать **ClientID** (длинная hex-строка, например `a1b2c3d4e5f6...`). Это публичный идентификатор — не секретный, но он понадобится для шага 2.

---

## Шаг 2. Получить access_token (2 минуты)

1. Подставить ClientID и открыть в браузере (где залогинен в Я.Аккаунт):

   ```
   https://oauth.yandex.ru/authorize?response_type=token&client_id=<ВАШ_CLIENT_ID>
   ```

2. Яндекс покажет страницу «Разрешить приложению victory62-kpi-fetcher доступ к...» — нажать **«Разрешить»**.

3. Браузер редиректит на `https://oauth.yandex.ru/verification_code#access_token=y0_XXXXXX...&token_type=bearer&expires_in=...`

   **`access_token`** — в URL после `#access_token=` (до следующего `&`).

   Пример: `y0_AgAAAAA1234567AAxxxRRRRRRRRRRRRRRRRRRRRRRRRRR`

4. Скопировать токен. Готово.

---

## Шаг 3. Проверить токен работает (30 секунд)

```bash
TOKEN='y0_AgAAAAA...'  # подставить свой

# Получить список твоих хостов:
curl -s -H "Authorization: OAuth $TOKEN" \
  https://api.webmaster.yandex.net/v4/user/

# → {"user_id": <число>}

# Список сайтов:
USER_ID='<ID из предыдущего ответа>'
curl -s -H "Authorization: OAuth $TOKEN" \
  "https://api.webmaster.yandex.net/v4/user/$USER_ID/hosts/" | python3 -m json.tool

# Должен показать host'ы (включая victory62.org с host_id = "https:victory62.org:443" или похожим)
```

Если оба возвращают JSON со внятными данными — токен рабочий.

---

## Шаг 4. Передать токен (безопасно)

Нельзя:
- ❌ Коммитить в git
- ❌ Слать в TG публичный чат
- ❌ Класть в `CLAUDE.md` или любую `.md` в репо

Куда положить:
- ✅ В production `.env` на VDS (рядом с `NEWS_INGEST_TOKEN`):
  ```
  YANDEX_WEBMASTER_TOKEN=y0_AgAAAAA...
  YANDEX_WEBMASTER_USER_ID=<твой user_id>
  ```
- ✅ Прислать мне в чате через Claude (он не идёт в commit'ы и не светится никому кроме тебя)

После того как добавлен на прод — `docker compose restart web` чтобы Rails подхватил.

---

## Что я смогу делать с токеном

После того как `YANDEX_WEBMASTER_TOKEN` и `YANDEX_WEBMASTER_USER_ID` в `.env`:

| Метрика | Endpoint | Куда отправлю |
|---|---|---|
| Страниц в индексе | `/v4/user/{id}/hosts/{host}/summary/` | KPI cache, weekly digest |
| Top-10 search queries | `/v4/user/{id}/hosts/{host}/search-queries/popular/` | dashboard, Telegram отчёты |
| Crawl errors (4xx/5xx) | `/v4/user/{id}/hosts/{host}/excluded-urls/` | alerts если spike |
| Sitemap status | `/v4/user/{id}/hosts/{host}/sitemaps/` | check для cron |
| ИКС (Index Quality Score) | `/v4/user/{id}/hosts/{host}/iks/` | brand health monitoring |

Можно сделать:
- **rake-task `yandex:webmaster:summary`** — выдаёт markdown-отчёт в TG раз в неделю
- **/admin/seo dashboard** — live counters в админке
- **Slack/TG alert** если страницы в индексе упали >10% w/w

---

## Срок действия

- Yandex OAuth токен **не истекает** автоматически
- Можно отозвать в любой момент: https://passport.yandex.ru/profile/access (раздел «Сторонние сервисы»)
- Если приложение `victory62-kpi-fetcher` удалить — все его токены инвалидируются

---

## Аналогичный setup для Google Search Console

Гугл сложнее — нужен service account JSON через Google Cloud Console + добавление service account email в GSC property как «Owner». Если нужно — отдельная инструкция (`google-search-console-setup.md`).

---

## Reference

- Yandex.Webmaster API docs: https://yandex.ru/dev/webmaster/doc/dg/concepts/about.html
- OAuth scopes: https://yandex.ru/dev/oauth/doc/dg/concepts/ya-oauth-intro.html
- Permissions list: https://yandex.ru/dev/webmaster/doc/dg/concepts/protocol.html
