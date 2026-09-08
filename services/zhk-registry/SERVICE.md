---
service: zhk-registry
owner: victory
kind: python-client
entrypoint: client.py
tests: cd services/zhk-registry && python3 -m unittest discover -v
deploy: —
depends_on: none
ported_from: —
port_status: done
repatriate_by: —
---

# zhk-registry

Каркас питоновской стороны «Реестра новостроек Рязани»: форма наблюдения
(`Observation`) и клиент, который шлёт наблюдения на вход Rails-вебхука
`POST /webhooks/zhk_ingest`. Сама выкачка внешних источников (ЕРЗ, сайты
застройщиков) — задел следующих задач, этой службой пока не делается.

`deploy: —` и `entrypoint: client.py` — на момент этой задачи у службы нет
самостоятельного процесса, который запускают по расписанию: `client.py`
это библиотека для будущего сборщика, а не CLI. Как только появится
исполняемый вход (крон-скрипт наподобие `urgent_collector.py`),
`entrypoint` и `deploy` обновляются вместе с ним.

Подробности — `README.md` (что делает, контракт) и `CLAUDE.md` (границы:
чего нельзя импортировать и трогать).
