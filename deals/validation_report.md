validation_report.md
--------------------

Проект: CrewAI — Contract Analysis (версия: 1.0)  
Проверка от: 2026-02-03

Цель отчёта
----------
Поймать ошибки до пользователя: синтаксис YAML, соответствие ссылок агент↔задача, импорт statements, зависимости в pyproject.toml и конфигурацию Docker. Выдать полный отчёт проверки и предложить конкретные патчи/рекомендации.

Краткий вывод (high‑level)
--------------------------
- YAML (agents.yaml) успешно распарсен — синтаксических ошибок нет. (Проверка выполнена инструментом yaml_lint_validate_tool.)
- Но найдены важные семантические/интеграционные несоответствия и потенциальные баги в коде и конфиге, которые нужно исправить до того, как давать проект пользователям или запускать процессы:
  1. Несогласованность идентификаторов Nextcloud: agents.yaml использует id: nextcloud_connector, тогда как tasks (tasks_spec.yml, dag.yml, config/tasks.yaml) используют nextcloud_upload. Это ломает ссылочную целостность.
  2. Ошибки в регулярных выражениях в src/generated_files/CrewAI/tools/parser_tool.py (лишние экранирования, из‑за чего regex не выполняют задуманную работу).
  3. Отсутствуют некоторые runtime‑зависимости в pyproject.toml (redis, Pillow) — код ожидает импорт redis и PIL, они не перечислены.
  4. Потенциальная проблема с упаковкой Python: проект использует layout src/ и пакеты в src/ — pyproject.toml не указывает секцию packages, поэтому при установке пакет generated_files может не включиться автоматически.
  5. Dockerfile: COPY poetry.lock* может привести к ошибке билда при отсутствии poetry.lock; нужны правки/харденинг образа (non‑root user, условная установка tesseract, меньший набор пакетов в prod image).
  6. Небольшие улучшения/безопасность: нормализация whitelist в WebSearchClient, корректные экспорты/импорты в db_client (Json), дополнительные defensive‑checks и замечания по работе с ключами/семи‑чувствительными данными.
- Рекомендую исправить указанные пункты и добавить CI (yaml lint + flake8/ruff + unit tests + safety/bandit) перед публикацией.

Детализованные проверки и найденные проблемы
-------------------------------------------

A. YAML — синтаксис и структурные проверки
- Проверены (yaml_lint_validate_tool) файл:
  - src/generated_files/CrewAI/config/agents.yaml — синтаксически валиден.
- Ручной просмотр остальных YAML (tasks_spec.yml, dag.yml, config/tasks.yaml) показал правильный YAML‑синтаксис (нет явных синтаксических ошибок), но есть семантические несоответствия (см. пункт B).

B. Ссылочная целостность agent ↔ task ↔ dag
- Проблема (высокая приоритетность):
  - agents.yaml содержит агент с id: nextcloud_connector (и name: "Nextcloud Connector"), а tasks_spec.yml / dag.yml / config/tasks.yaml используют id: nextcloud_upload (и он выступает в зависимостях/edges). Это приводит к тому, что оркестратор/регистрационные механизмы, которые сопоставляют task id → agent id, не найдут соответствия.
  - Mеста, где используется nextcloud_upload:
    - tasks_spec.yml: id: nextcloud_upload (Nextcloud Connector (upload))
    - dag.yml: nodes include nextcloud_upload; edges target nextcloud_upload
    - config/tasks.yaml: task_runtimes: nextcloud_upload
  - Mеста, где используется nextcloud_connector:
    - src/generated_files/CrewAI/config/agents.yaml: id: nextcloud_connector
    - crew_design_spec.yml (в документе) — использует nextcloud_connector
- Рекомендуемое решение: унифицировать идентификатор. Предпочтительный вариант — переименовать agent в agents.yaml в nextcloud_upload (чтобы соответствовать tasks и dag), либо изменить все упоминания nextcloud_upload на nextcloud_connector. Ниже — предлагаемый патч (рекомендуется применить один из вариантов, я предлагаю унифицировать в сторону nextcloud_upload, т.к. tasks и dag уже используют именно его).

Патч-1 (унифицировать agents → nextcloud_upload)
Файл: src/generated_files/CrewAI/config/agents.yaml
Изменение (diff / snippet):

--- a/src/generated_files/CrewAI/config/agents.yaml
+++ b/src/generated_files/CrewAI/config/agents.yaml
@@
-  - id: nextcloud_connector
-    name: "Nextcloud Connector"
+  - id: nextcloud_upload
+    name: "Nextcloud Connector (upload)"
@@
-    integrations: ["ingest_agent", "orchestrator", "auth_audit", "backup_and_monitoring"]
+    integrations: ["ingest_agent", "orchestrator", "auth_audit", "backup_and_monitoring"]
@@
-    integrations: ["auth_audit", "worker_queue", "database", "nextcloud_connector", "search_indexer"]
+    integrations: ["auth_audit", "worker_queue", "database", "nextcloud_upload", "search_indexer"]

(Требуется заменить все ссылки внутри agents.yaml, где встречается nextcloud_connector, на nextcloud_upload; это гарантирует совпадение со tasks и dag. При выборе обратной стратегии — изменить tasks/dag вместо agents.)

C. Кодовые ошибки / импорт‑issues — основные места
- src/generated_files/CrewAI/tools/parser_tool.py — ошибки в регулярных выражениях:
  - Текущий код использует двойное экранирование (например r"...\\d..." и r"...\\s...") — из‑за этого regex не будут срабатывать как ожидается (они ищут буквальные "\d" в тексте).
  - Примеры проблемных строк:
    - SECTION_HEADING_RE = re.compile(r"(?m)^\s*(?:Статья|Раздел|Section|ARTICLE|\d+[\).])*\\s*(.+)$", re.IGNORECASE)
    - DATE_RE = re.compile(r"(\\d{1,2}\\.\\d{1,2}\\.\\d{2,4})")
    - AMOUNT_RE = re.compile(r"(\\d[\\d\\s]*[,\\.]\\d{2}|\\d[\\d\\s]{0,})\\s*(руб\\.?|RUB|₽)?", re.IGNORECASE)
  - Рекомендация: заменить на корректные raw‑regex (без лишних backslash).
  - Патч-2 (parser_tool regex fix):

Файл: src/generated_files/CrewAI/tools/parser_tool.py
Заменить соответствующие строки на:

SECTION_HEADING_RE = re.compile(r"(?m)^\s*(?:Статья|Раздел|Section|ARTICLE|\d+[\)\.]*)\s*(.+)$", re.IGNORECASE)
PARTY_RE = re.compile(r"(?P<name>[А-ЯЁ][\w\s\.,\-]{2,100})(?:[,;]\s*ИНН[:\s]?\s*(?P<inn>\d{10,12}))?", re.IGNORECASE)
DATE_RE = re.compile(r"(\d{1,2}\.\d{1,2}\.\d{2,4})")
AMOUNT_RE = re.compile(r"(\d[\d\s]*[.,]\d{2}|\d[\d\s]*)\s*(руб\.?|RUB|₽)?", re.IGNORECASE)

Пояснение: исправления убирают лишние экранирования, корректируют шаблоны для русских дат и сумм, а также безопаснее парсят ИНН.

- src/generated_files/CrewAI/tools/db_client.py
  - В insert_document_metadata используется psycopg2.extras.Json, однако модуль psycopg2.extras.Json не импортирован явно. Рабочий код использует psycopg2.extras.Json (через psycopg2.extras) — лучше импортировать Json явно, чтобы избежать предупреждений и быть явными.
  - Патч-3:

Файл: src/generated_files/CrewAI/tools/db_client.py
Изменение импорта:
from psycopg2.extras import RealDictCursor, Json

- src/generated_files/CrewAI/tools/web_search_client.py
  - Создание whitelist: выражение несколько хрупкое и может породить пустые строки в сетe. Рекомендую нормализовать и отфильтровать пустые строки.
  - Патч-4 (normalise whitelist):

В __init__:

if whitelist is None:
    raw = os.getenv("LEGAL_WHITELIST_DOMAINS", "")
    self.whitelist = {d.strip() for d in raw.split(",") if d.strip()}
else:
    self.whitelist = {d.strip() for d in whitelist if d and d.strip()}

D. Зависимости в pyproject.toml (важность: высокая → runtime ошибки)
- Обнаружено: код ожидает библиотеки, не перечисленные в [tool.poetry.dependencies]:
  - src/generated_files/CrewAI/tools/task_queue.py импортирует redis (если redis отсутствует, TaskQueue __init__ выбросит RuntimeError). В pyproject.toml отсутствует зависимость redis.
  - src/generated_files/CrewAI/tools/ocr_tool.py использует PIL (Pillow) — pytesseract часто требует Pillow; в pyproject.toml Pillow отсутствует.
- Рекомендация: добавить зависимости:
  - redis (например "^4.6.0") — актуализировать версию под ваши требования.
  - Pillow (например "^10.0.0").
- Дополнительно: проверить корректность имени пакета python-nextcloud (в pyproject.toml указано python-nextcloud = "^0.4.0"). Это название может отличаться в PyPI (популярный клиент называется nextcloud‑ or py‑nextcloud; рекомендуется проверить и зафиксировать корректный пакет/версию). Если вы не уверены — уточните и pin конкретную проверенную версию. (Примечание: в рамках этого отчёта я не делал внешний поиск; просьба проверить пакет через pip/Poetry локально или уточнить.)

Патч-5 (pyproject additions)

Файл: pyproject.toml (фрагмент)
Добавить в [tool.poetry.dependencies]:

redis = "^4.6.0"
Pillow = "^10.0.0"

Также добавить секцию packages, чтобы packaging обнаруживал модули в src/:

[tool.poetry]
# ... (существующие поля)
packages = [
  { include = "generated_files", from = "src" }
]

E. Упаковка / packaging note
- Текущее pyproject.toml не определяет packages/from. При установке "pip install ." система может не включить package modules из src/. Добавление packages stanza (как в Патч‑5) решит проблему и сделает пакет импортируемым после установки.

F. Dockerfile — потенциальные проблемы и hardening
- Текущая строка:
  COPY pyproject.toml poetry.lock* /app/
  - Если poetry.lock отсутствует, glob poetry.lock* в COPY приведёт к ошибке при docker build (COPY требует существующих файлов). Это часто ломает билды на CI.
- Рекомендации:
  1. Не копировать poetry.lock* с glob; копируйте pyproject.toml и отдельно poetry.lock (если он есть). Простой safe‑вариант — только COPY pyproject.toml /app/ ; COPY src /app/src
  2. Если образ должен поддерживать OCR (ON_PREM) — добавьте установку Tesseract и языковой пакет (tesseract-ocr-rus) в RUN apt-get install. Учитывайте размер образа — ставьте это только в dev‑image или в отдельный image для OCR.
  3. Добавить non‑root user (appuser) и переключиться на него.
  4. Обеспечить что .env не копируется в образ.
- Патч-6 (Dockerfile improvements — snippet):

# copy project files (do NOT glob poetry.lock to avoid build errors)
COPY pyproject.toml /app/
COPY src /app/src
COPY README.md /app/README.md
COPY .env.example /app/.env.example

# Install system deps (including optional OCR; make optional via build arg)
ARG INSTALL_OCR=false
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc libpq-dev git ca-certificates libmagic1 \
    && if [ "$INSTALL_OCR" = "true" ] ; then apt-get install -y tesseract-ocr tesseract-ocr-rus ; fi \
    && rm -rf /var/lib/apt/lists/*

# create non-root user
RUN useradd -ms /bin/bash appuser
USER appuser

# install python deps (as non-root ensure virtual envs or --user if needed)
RUN python -m pip install --upgrade pip build \
    && python -m pip install .

CMD ["python", "-m", "generated_files.CrewAI.main"]

G. Другие замечания по качеству кода / security / ops
- Secrets/Kлючи:
  - .env.example содержит NEXTCLOUD_TOKEN и VAULT_TOKEN — ОБЯЗАТЕЛЬНО: инструкции по использованию Vault/HSM в production должны быть задокументированы. Никогда не хранить реальные токены в репозиториях.
- Audit:
  - AuditLogger пишет в путь, указанным в AUDIT_LOG_PATH; рекомендуется обеспечить append‑only/immutable хранение (WORM) для аудита в production.
- web_search_client:
  - Убедиться, что caching реализован (легальные результаты должны кешироваться в local legal_db с отметкой timestamp + source).
  - Провести rate limiting + circuit breaker для внешних вызовов.
- tests:
  - Добавить unit tests для parser_tool (regex correctness), NER fallback, TaskQueue (моки redis), NextcloudConnector (mocked HTTP), WebSearchClient (whitelist behaviour).
- CI:
  - Добавить GitHub Actions / GitLab CI:
    - YAML lint for project YAMLs
    - Python static checks: ruff/flake8, black check
    - pytest
    - safety/bandit scan of dependencies

H. Предложения по быстрым исправлениям (patches summary)
-------------------------------------------------------
1) Unify nextcloud id:
   - Apply Патч‑1 to src/generated_files/CrewAI/config/agents.yaml (replace nextcloud_connector → nextcloud_upload and replace all internal occurrences).
   - Then run grep across repository to ensure no leftover references: grep -R "nextcloud_connector" -n .

2) Fix parser regex:
   - Apply Патч‑2 to src/generated_files/CrewAI/tools/parser_tool.py and add unit tests demonstrating section split and date/amount extraction.

3) Add missing imports and small fixes:
   - Apply Патч‑3 to src/generated_files/CrewAI/tools/db_client.py (import Json).
   - Normalize whitelist in web_search_client as per Патч‑4.

4) Update pyproject.toml dependencies and packaging:
   - Add redis and Pillow and packages stanza as in Патч‑5.
   - Pin/verify python‑nextcloud package name and version (manual verification required).

5) Harden Dockerfile:
   - Apply recommended changes in Патч‑6. Use build arg INSTALL_OCR to optionally install Tesseract.

I. Команды для проверки и тестирования после фиксов
---------------------------------------------------
(в root проекта)

1) Локальная проверка YAML:
   - pip install yamllint
   - yamllint src/generated_files/CrewAI/config/*.yaml
   - yamllint tasks_spec.yml dag.yml config/tasks.yaml

2) Запуск unit tests (после добавления тестов):
   - python -m venv .venv && source .venv/bin/activate
   - pip install -r <requirements-dev> (или poetry install)
   - pytest -q

3) Проверка упаковки:
   - Build wheel: python -m build
   - pip install dist/crewai-1.0.0-py3-none-any.whl
   - python -c "import generated_files.CrewAI; from generated_files.CrewAI.crew import Crew; print(Crew.get_agents()[:1])"

4) Docker build (dev image):
   - docker build --build-arg INSTALL_OCR=true -t crewai:dev .

J. Recommended roadmap (next steps)
----------------------------------
1) Сразу исправить несоответствие nextcloud id и regex в parser_tool.
2) Добавить недостающие зависимости (redis, Pillow) и packages stanza в pyproject.toml; проверить корректность python-nextcloud package.
3) Добавить модульные тесты для parser_tool, web_search_client whitelist behaviour, NextcloudConnector (mocked), TaskQueue (mocked redis).
4) Добавить CI (GitHub Actions) с этапами lint → test → build.
5) До включения web_search/externals заполнить whitelist_domains и настроить proxy + audit trail.
6) Принять решение по policy external LLMs (on‑prem vs cloud) и зафиксировать в security policy.
7) При наличии требований локализации в РФ — зафиксировать требования к offsite backups и storage region поля в nextcloud upload responses (в tasks/agents).

Полные патчи (копировать/вставить)
----------------------------------
Ниже — агрегированные патчи/файлы (предоставлены в виде изменений/фрагментов). Применяйте аккуратно, делайте ревью и запускайте тесты.

1) agents.yaml — unify nextcloud id
(см. Патч‑1 выше — заменить id и все упоминания nextcloud_connector → nextcloud_upload)

2) parser_tool.py — regex fixes
(см. Патч‑2 выше — заменить SECTION_HEADING_RE, PARTY_RE, DATE_RE, AMOUNT_RE на предложенные строки)

3) db_client.py — импорт Json
(см. Патч‑3 выше)

4) web_search_client.py — whitelist normalisation
(см. Патч‑4 выше)

5) pyproject.toml — add deps and packages
(см. Патч‑5 выше)

6) Dockerfile — robust copy / optional OCR / non‑root user
(см. Патч‑6 выше)

Замечания по верификации пакетов (manual tasks)
-----------------------------------------------
- Проверьте в вашей среде (или с помощью pip/poetry) корректные имена/версии для:
  - python-nextcloud — убедитесь, что это реальное PyPI‑имя в вашем окружении; иначе замените на правильный клиент (py3‑nextcloud / py‑nextcloud / nextcloud-client) и pin версию.
  - elasticsearch – текущая версия ^8.0.0 может требовать дополнительные конфигурации (в зависимости от сервера Elastic/OpenSearch).
- Уточните, нужны ли асинхронные клиенты (aioredis) вместо синхронных (redis) для вашей архитектуры (в worker/async коде может понадобиться async API).

Заключение
----------
YAML синтаксически корректен (agents.yaml успешно распаршен). Однако проект содержит важные семантические несоответствия (главным образом — nextcloud идентификаторы), несколько багов в коде (regex в parser_tool) и недостающие runtime зависимости (redis, Pillow). Исправление отмеченных мест — обязательное минимальное действие перед тестированием/пользованием комплекта.

Если хотите, могу:
- Применить предложенные патчи и вернуть diff‑файлы для каждого изменяемого файла (готовые unified diffs).
- Выполнить аналогичную YAML‑валидацию для всех YAML (включая dag.yml, tasks_spec.yml, config/tasks.yaml) с выводом точного списка всех ссылок/ID и отчётом об их согласованности (полный cross‑reference matrix).
- Сгенерировать базовый набор unit‑тестов (pytest) для parser_tool и web_search_client.
- Подготовить GitHub Actions workflow (CI) с yamllint, ruff/black check, pytest.

Выберите следующее действие: "apply_patches" (получить готовые diffs), "validate_all_yaml" (полная проверка ссылочной целостности), "add_tests" (создать тесты), или задайте другой запрос.