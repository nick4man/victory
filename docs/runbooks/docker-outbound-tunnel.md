# Outbound docker-контейнеров через sing-box — план

Дата составления: 14.10.26. Статус: **текущая схема уже работает** (см. §1),
документ описывает механику, гэпы и план доработок. Ничего из перечисленного
в §4 на проде ещё не применено.

## 1. Текущее состояние (проверено 14.10.26)

На хосте `victory` работает `sing-box@user.service` (sing-box 1.13.11,
`/usr/bin/sing-box -D /var/lib/sing-box-user -c /etc/sing-box/user.json`),
inbound `tun` (`tun0`, `10.255.255.1/30`, `auto_route` + `strict_route`),
таблица маршрутизации 2022 (`default via 10.255.255.2 dev tun0`).

Фактическая маршрутизация прод-контейнеров — уже соответствует целевой:

| Контейнер | RU (`yandex.ru/internet/api/v0/ip`) | non-RU (`ifconfig.me`) |
|---|---|---|
| victory-web-1 | `37.112.103.28` (direct) | `93.95.229.192` (туннель) |
| victory-sidekiq-1 | `37.112.103.28` (direct) | `93.95.229.192` (туннель) |
| victory-conveyor-1 | `37.112.103.28` (direct) | — |
| victory-publisher-1 | `37.112.103.28` (direct, проверка через python3) | — |
| victory-zhk-registry-1 | `37.112.103.28` (direct, проверка через python3) | — |

`37.112.103.28` — реальный RU egress IP хоста; `93.95.229.192` — VLESS-сервер
(туннельный выход).

Вывод: отдельной настройки docker не требуется — контейнеры попадают в туннель
автоматически через policy routing хоста (см. §2). Инцидент 13.10.26
(`Kpi::AgencyDigestJob`, SSL EOF / Net::OpenTimeout к `149.154.166.110`) —
это **нестабильность туннеля**, а не обход его: `peeraddr` в ошибке — адрес
назначения до перехвата tun0, это не доказывает direct-путь.

## 2. Механика: почему контейнеры в туннеле

`auto_route` sing-box ставит ip rules (вывод `ip rule`):

```
9000:  from all to 10.255.255.0/30 lookup 2022
9001:  from all lookup 2022 suppress_prefixlength 0
9003:  not from all iif lo lookup 2022      ← форвардинг с docker-мостов
9010:  from all nop
32766: from all lookup main
```

Пакет из любого контейнера приходит на хост с `iif = br-xxx` (docker bridge),
попадает под правило 9003 → таблица 2022 → `default via tun0` → sing-box
терминирует соединение и дальше роутит по своим правилам:

1. `ip_is_private` → `direct` (RFC1918, docker-мосты 172.x/192.168.x, LAN
   10.10.x — не уходят в туннель);
2. `geosite-category-ads-all` → reject;
3. `geosite-ru` + `geoip-ru` → `direct` (RU-сервисы видят RU IP);
4. `final` → `proxy` (urltest `auto` по трём VLESS-Reality outbounds).

Следствия:

- **Новые контейнеры/сети подхватываются автоматически** — правило 9003
  не привязано к конкретным мостам.
- DNS контейнеров (`127.0.0.11` → резолвер хоста `10.10.10.1`) идёт мимо
  sing-box (ip rule 9002 исключает dport 53 из таблицы 2022). На маршрутизацию
  это не влияет: sing-box sniff'ит SNI/домен из трафика и матчит geosite-ru,
  а по IP работает geoip-ru. Принимаем как данность.
- Контейнеры в сети `host` (нет таких в прод-стеке) шли бы как трафик хоста.

## 3. Гэпы и риски

1. **`.ru` / `.su` как TLD не гарантированы.** `geosite-category-ru` —
   каталог конкретных доменов российских сервисов, а не «вся зона .ru».
   Домен на `.ru`/`.su` вне каталога уйдёт в туннель → RU-сервер увидит
   иностранный IP (риск блокировок со стороны RU-сервисов). `geoip-ru`
   подстраховывает только если домен резолвится в RU IP и sniff не сработал.
2. **Логи sing-box недоступны пользователю `q`**: `journalctl -u sing-box@user`
   пуст (группа `systemd-journal`/`adm` отсутствует). Диагностика инцидентов
   туннеля слепа — причина SSL EOF 13.10.26 не подтверждена.
3. **urltest флаппинг**: `interval: 3m`, три outbound'а; переключение рвёт
   длинные соединения (TLS handshake EOF как раз так выглядит).
4. **Нет мониторинга** туннельного пути из контейнеров — о деградации узнаём
   по упавшим джобам.
5. **Кольцевая зависимость алертинга**: аварийные DM директорам идут через
   Telegram, который сам идёт через туннель. При мёртвом туннеле алерт может
   не уйти (правда, при остановленном sing-box таблица 2022 пуста → трафик
   уходит direct, и TG снова недоступен уже по причине блокировки RKN).

## 4. План доработок

Каждый шаг — бэкап перед правкой, проверка после (§5), откат по §6.

### Шаг 0. Доступ к логам (предусловие диагностики)

```bash
sudo usermod -aG systemd-journal q   # перелогиниться
journalctl -u sing-box@user -f
```

### Шаг 1. Явный direct для зон `.ru` / `.su` (и `.рф`)

В `/etc/sing-box/user.json`, в `route.rules`, **после** правила reject
рекламы и **перед** rule_set `geosite-ru`/`geoip-ru` добавить:

```json
{
  "domain_suffix": [".ru", ".su", ".xn--p1ai"],
  "outbound": "direct"
}
```

Зачем: закрывает гэп №1 независимо от полноты каталога geosite-category-ru.
Проверка синтаксиса перед применением: `sing-box check -c /etc/sing-box/user.json`,
применение: `sudo systemctl reload sing-box@user` (или restart — reload не
рвёт существующие соединения).

### Шаг 2. Стабилизация urltest

В outbound `auto`:

```json
{
  "type": "urltest",
  "tag": "auto",
  "outbounds": ["IS-gRPC", "IS-gRPC-alt", "IS-BS1-Vision"],
  "url": "https://www.gstatic.com/generate_204",
  "interval": "5m",
  "tolerance": 80,
  "interrupt_exist_connections": false
}
```

Зачем: не разрывать живые соединения при смене лучшего outbound'а
(гэп №3). `interrupt_exist_connections: false` — дефолт в sing-box 1.13,
фиксируем явно.

### Шаг 3. Мониторинг туннельного пути

Скрипт `bin/tunnel-check` (в репозиторий, на хосте — в cron, 5 записей
системного crontab уже есть по образцу): из `victory-web-1` и
`victory-sidekiq-1` проверять

- `https://api.telegram.org/` → HTTP 302 (туннель жив, TG доступен);
- `https://yandex.ru/internet/api/v0/ip` → тело `37.112.103.28` (RU direct
  не сломан);
- `https://ifconfig.me` → `93.95.229.192` (выход = туннель).

При несовпадении — алерт в work-bot директорам + запись в
`log/tunnel-check-cron.log`. Учесть кольцевую зависимость (гэп №5): при
полностью мёртвом туннеле TG-алерт может не дойти — это принимаем, SMSC
fallback не делаем (отдельная задача, если понадобится).

### Шаг 4 (опционально). healthcheck-зависимость rollout

`bin/rollout` после поднятия стека вызывает `bin/smoke`; добавить туда же
вызов `bin/tunnel-check` (из шага 3) — выкатка с мёртвым туннелем помечается
в выводе, но не блокируется (туннель — не часть образа).

## 5. Проверка после каждого изменения

```bash
# из каждого прод-контейнера (curl есть в web/sidekiq/conveyor;
# в publisher/zhk-registry — python3 -c urllib):
docker exec victory-web-1 curl -s --max-time 8 https://ifconfig.me
#   ожидание: 93.95.229.192 (туннель)
docker exec victory-web-1 curl -s --max-time 8 \
  'https://yandex.ru/internet/api/v0/ip' -H 'Accept: application/json'
#   ожидание: "37.112.103.28" (RU direct)
docker exec victory-web-1 curl -s -o /dev/null -w '%{http_code}\n' \
  --max-time 8 https://api.telegram.org/
#   ожидание: 302
docker exec victory-web-1 curl -s -o /dev/null -w '%{http_code}\n' \
  --max-time 8 'https://catalog.api.2gis.com/3.0/markers'
#   ожидание: 200/4xx, но НЕ timeout (RU-сервис доступен)
# private-сети: сайт отвечает (postgres/redis достижимы):
bin/smoke
```

После шага 1 дополнительно: выбрать домен `.su`/`.ru` вне каталога
geosite-category-ru и убедиться по `yandex.ru/internet`-приёму, что выход
RU (или по логу sing-box `outbound: direct`).

## 6. Откат

```bash
# конфиг бэкапим перед каждой правкой (на хосте уже принято: user.json.bak-<дата>)
sudo cp /etc/sing-box/user.json /etc/sing-box/user.json.bak-$(date +%d.%m.%y)
# откат:
sudo cp /etc/sing-box/user.json.bak-<дата> /etc/sing-box/user.json
sudo systemctl restart sing-box@user
# проверка — команды §5
```

Полное отключение туннеля (аварийно): `sudo systemctl stop sing-box@user` —
таблица 2022 перестаёт работать, контейнеры уходят direct через main-таблицу
(TG при этом недоступен — известное поведение до введения туннеля).

## 7. Открытые вопросы

1. Причина SSL EOF 13.10.26 — без логов sing-box (шаг 0) не подтверждена;
   гипотеза — смена outbound'а urltest посреди TLS-handshake (шаг 2).
2. DNS контейнеров идёт через роутер `10.10.10.1` в обход sing-box DNS-правил
   (в т.ч. reject ads-zone не применяется к резолву). Принять как данность
   или перенастроить docker DNS на sing-box (`dns` в compose) — решить после
   шага 0 по логам.
3. Нужен ли SMSC-fallback для алертов при мёртвом туннеле (гэп №5).

## 8. Альтернатива (не выбрана)

Per-container `HTTPS_PROXY` на mixed-inbound sing-box (`10.10.10.141:port`)
вместо прозрачного tun: явный контроль из compose, но RU-bypass пришлось бы
кодировать в `NO_PROXY` каждого сервиса (домены, не IP), Ruby/Faraday по
умолчанию игнорирует часть proxy-ENV, и web-контейнер обслуживает входящие —
риск сломать больше, чем починить. Текущая прозрачная схема уже даёт целевую
маршрутизацию без единой правки контейнеров.
