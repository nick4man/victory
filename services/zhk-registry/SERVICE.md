---
service: zhk-registry
owner: victory
kind: python-cron
entrypoint: run.py
tests: cd services/zhk-registry && python3 -m unittest discover -v
deploy: user crontab on prod host, main checkout — see crontab.example
depends_on: none
ported_from: —
port_status: done
repatriate_by: —
---

# zhk-registry

Питоновская сторона «Реестра новостроек Рязани»: обходит открытые
источники (ЕРЗ, сайты застройщиков), отправляет наблюдения на вход
Rails-вебхука `POST /webhooks/zhk_ingest` и репортует сводку прогона на
`POST /webhooks/zhk_ingest/summary`.

`run.py` — исполняемый вход, ставится в крон раз в неделю
(`crontab.example`). `entrypoint: client.py` из более ранней версии этого
файла устарел: `client.py` остаётся библиотекой (`IngestClient`), но
процессом, который реально запускают по расписанию, стал `run.py`.

Подробности — `README.md` (что делает, контракт) и `CLAUDE.md` (границы:
чего нельзя импортировать и трогать).
