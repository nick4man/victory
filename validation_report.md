validation_report.md (complete content) with findings, recommended fixes/patches and concrete diffs.

--- BEGIN validation_report.md ---

Project: CrewAI — Аналитика договоров купли‑продажи для агентства недвижимости (РФ)
Generation date (analysis): 2026-02-03
Author of validation: Инженер контроля качества — CrewAI

Цель проверки
- Найти и зафиксировать синтаксические ошибки YAML, нарушения ссылочной целостности agent↔task, проблемные операторы импорта, несовместимости/рекомендации по зависимостям (pyproject.toml) и проблемы в Dockerfile/сборке.
- Предложить конкретные исправления (патчи/диффы) и рекомендации по проверке/тестированию.

Краткий итог (high-level)
- Найдены блокирующие синтаксические ошибки в src/crewai_contracts_analytics/config/agents.yaml (malformed block / неправильные escaped/newline и отступы).
- Найдены критичные проблемы в tasks_spec.yml: некорректное использование YAML alias/anchor (*defaults.output_envelope) — alias не определён.
- config/tasks.yaml (в src) и dag.yml и llm_matrix.yml синтаксически корректны, но есть стилистические/интеграционные предупреждения (placeholder-значения, соглашения по неймингу).
- В code: crew.py импорт от "crewai.framework" оформлен в try/except — функционально безопасно, но рекомендую сузить except до ImportError и логировать явное предупреждение.
- pyproject.toml: есть явные рекомендации по исправлению секции packages (Poetry ожидает include = "package_name" и from = "src"), и общий призыв — создать/зафиксировать poetry.lock, проверить совместимость версий библиотек и добавить requirements.txt для альтернативного pip-пути.
- Dockerfile: потенциальная ошибка COPY pyproject.toml poetry.lock* /app/ — если poetry.lock отсутствует COPY с шаблоном может сломаться в Docker build (в зависимости от Docker версии/контекст). Рекомендации по устойчивому COPY и/или включению poetry.lock в репозиторий.
- Конвенции нейминга mapped_service / service identifiers: в spec и agents используются разные формы (IngestionAgent / ingestion-service / ingestion_service). Рекомендация — унифицировать идентификаторы сервисов (machine-readable ids) и поддерживать маппинг.

Детализованные результаты (файлы, обнаруженные проблемы, рекомендации и патчи)

1) src/crewai_contracts_analytics/config/agents.yaml
Статус: Ошибка парсинга YAML (blocking)

Найдено (из проверки yaml_lint_validate_tool):
- Mapping/block error при обработке блока, связанного с ClauseClassifier (responsibilities). Причина: в файле присутствует некорректная вставка текста с literal '\n' и нарушениями отступов, вследствие чего парсер YAML ломается (см. Observation: Mapping values are not allowed here).
- Из-за этого весь YAML перестаёт валидироваться; downstream-интеграторы (crew.py загрузчик) получит None из _load_yaml и поведение будет некорректным.

Рекомендация:
- Исправить повреждённый участок: заменить проблемный участок на корректно отформатированный YAML. Убедиться, что все блоки массивов (- id: ...) корректно отступлены, без встроенных строковых экранированных последовательностей '\n'.

Предлагаемый фикс (patch): исправить блок, начиная от clause_classifier_agent до risk_detector_agent, с корректными отступами и без внедрённых escaped newlines.

Патч (унифицированный diff, пример):
--- a/src/crewai_contracts_analytics/config/agents.yaml
+++ b/src/crewai_contracts_analytics/config/agents.yaml
@@
   - id: clause_classifier_agent
     role_name: "ClauseClassifier"
     mapped_service: "nlp-orchestrator (component)"
     domain_expertise:
       - классификация клаузул по шаблонам: переход права, обременения, сроки, ответственность
-    responsibilities:
-      - сегментация и классификация клаузул\n    internet_access: \"no\"\n\n  - id: risk_detector_agent\n    role_name: \"RiskDetector\"\n    mapped_service: \"nlp-orchestrator (component)\"\n    domain_expertise:\n      - выявление юридических рисков, contraditions, missing clauses\n    responsibilities:\n      - применять правила и ML для оценивания рисков\n    tools_and_integrations:\n      - rule-engine (Drools / custom), ML models\n    internet_access: \"no\"\n
+    responsibilities:
+      - сегментация и классификация клаузул
+    internet_access: "no"
+
+  - id: risk_detector_agent
+    role_name: "RiskDetector"
+    mapped_service: "nlp-orchestrator (component)"
+    domain_expertise:
+      - выявление юридических рисков, contradictions, missing clauses
+    responsibilities:
+      - применять правила и ML для оценивания рисков
+    tools_and_integrations:
+      - rule-engine (Drools / custom)
+      - ML models
+    internet_access: "no"
 
(Комментарий: выше — пример исправления. Важно: при правке проверьте, чтобы все перечисления agents: - id: ... были корректно отступлены и не было лишних управляющих символов '\\n'.)

Дополнительные проверки:
- После исправления запустить yaml validator/linters и unit tests (в частности main.py, crew._load_yaml).
- Проверить, что agents_cfg импортируется и что len(agents_cfg["agents"]) соответствует ожидаемому числу агентов.

2) tasks_spec.yml (файл в корне проекта)
Статус: Ошибка парсинга YAML (alias/anchor misuse — blocking)

Найдено:
- Во множестве мест используется выражение:
    envelope: *defaults.output_envelope
  Но в YAML нет никакого alias &defaults.output_envelope; YAML-алиасы должны ссылаться на конкретный anchor (&name).
- Конкретная ошибка: "Unknown alias: defaults.output_envelope" (yaml parser).

Объяснение:
- В исходном файле defaults.output_envelope — это путём к ключу в структуре YAML, но YAML-алиасы/якоря не работают как JSONPath. Нужно задать anchor в той точке, где определён шаблон (output_envelope), например:
    output_envelope: &output_envelope
      fields: ...
  и затем в задачах:
    envelope: *output_envelope

Рекомендация:
- Переопределите defaults.output_envelope с добавлением anchor (&output_envelope), затем замените все вхождения '*defaults.output_envelope' на '*output_envelope'.

Патч (рекомендуемый фрагмент изменения):
--- a/tasks_spec.yml
+++ b/tasks_spec.yml
@@
   output_envelope:
-    # Унифицированная оболочка для всех task outputs для облегчения downstream-потребления
-    fields:
+    # Унифицированная оболочка для всех task outputs для облегчения downstream-потребления
+    &output_envelope
+    fields:
       document_id: "string (uuid) — идентификатор исходного документа"
       artifact_id: "string (uuid) — id артефакта/записи"
@@
-      envelope: *defaults.output_envelope
+      envelope: *output_envelope

(Примечание: заменить во всех местах, где встречается '*defaults.output_envelope').

Дополнительно:
- Альтернативный подход — не использовать YAML-алиасы, а держать output_envelope как отдельный schema файл и сделать include/merge на этапе генерации кода. Но anchor/alias — хороший и простой путь.

3) src/crewai_contracts_analytics/config/tasks.yaml
Статус: OK (валидация пройдена), замечания:
- Значение environment: "production|staging" — корректно как строка, но это шаблон; перед деплоем нужно заменить на конкретное окружение. Рекомендую использовать либо список поддерживаемых значений, либо явную переменную (например environment: "production").
- Убедитесь, что docker_image placeholders заменены в CI/CD/Infra (в репо используются образцы crewi/...:latest — OK для шаблона).

Рекомендации:
- Добавить schema validation при CI (yamllint + jsonschema при необходимости).
- Убедиться, что secret_refs используются, и секреты не попадают в репозиторий.

4) dag.yml
Статус: OK (валидный YAML)
Замечания/рекомендации:
- DAG содержит условные выражения в виде строк (например "parse_report.detected_scanned_hint == true"). Это допустимо как декларативная метаинформация, но оркестратор должен уметь безопасно/детерминированно интерпретировать их. Проверьте, как ваша runtime-система будет вычислять эти выражения (evaluate in safe sandbox / do not eval arbitrary code).
- Проверьте согласованность task ids в dag.yml и в tasks_spec.yml / config/tasks.yaml — в этой поставке task ids совпадают (например task_ingest, task_parse). Рекомендуется добавить интеграционные unit-tests, которые загружают dag.yml и tasks_spec.yml и проверяют, что все referenced task ids существуют.

5) llm_matrix.yml
Статус: OK, warnings:
- В исходном embedded файле был потенциальный ведущий '|' — проверьте реальный файл в репозитории, чтобы исключить, что весь YAML не оказался как одна строка. Если файл начинается с 'version: "1.0"' — всё ок.
- Структура сложная (вложенные primary/fallback поля) — хорошо, но добавьте JSON Schema для валидации и тесты, которые проверяют правильность ключей (primary may be string or mapping).

6) Код: src/crewai_contracts_analytics/crew.py
Найдено: не-критичные, но рекомендованные правки.
- Текущее:
try:
    from crewai.framework import CrewBase  # hypothetical import

    @CrewBase(...)
    class Crew(CrewBase):
        ...
except Exception:
    class Crew:
        ...

Проблемы/рекомендации:
- Ловить широкое Exception опасно — оно скрывает не только ImportError, но и ошибки в коде декоратора CrewBase или прочие ошибки импорта. Предлагаю ловить ImportError только, и логировать предупреждение с traceback для диагностики.

Рекомендуемый патч:
--- a/src/crewai_contracts_analytics/crew.py
+++ b/src/crewai_contracts_analytics/crew.py
@@
-try:
-    from crewai.framework import CrewBase  # hypothetical import
-
-    @CrewBase(name="crewai_contracts_analytics", agents=str(AGENTS_FILE), tasks=str(TASKS_FILE))
-    class Crew(CrewBase):
-        """Registered Crew for contract analytics project."""
-        pass
-
-except Exception:
-    # Если framework не доступен — экспортируем метаданные для внешней регистрации
-    class Crew:
-        """Lightweight descriptor used for manual registration by integrator."""
-
-        name = "crewai_contracts_analytics"
-        agents = agents_cfg
-        tasks = tasks_cfg
-
-        def __repr__(self):
-            return f"<Crew name={self.name} agents={len(self.agents.get('agents', [])) if self.agents else 0}>"
+try:
+    from crewai.framework import CrewBase  # hypothetical import
+
+    @CrewBase(name="crewai_contracts_analytics", agents=str(AGENTS_FILE), tasks=str(TASKS_FILE))
+    class Crew(CrewBase):
+        """Registered Crew for contract analytics project."""
+        pass
+
+except ImportError:
+    # Framework not available — export metadata for manual registration.
+    import warnings
+    warnings.warn("crewai.framework.CrewBase is not available; using fallback Crew descriptor. Integrator should register the Crew with the real framework.", ImportWarning)
+
+    class Crew:
+        """Lightweight descriptor used for manual registration by integrator."""
+
+        name = "crewai_contracts_analytics"
+        agents = agents_cfg
+        tasks = tasks_cfg
+
+        def __repr__(self):
+            return f\"<Crew name={self.name} agents={len(self.agents.get('agents', [])) if self.agents else 0}>\"
 
(Комментарий: это делает поведение более явным и не скрывает реальные ошибки в случае, если импорт прошёл, но декоратор упал.)

7) Совместимость зависимостей — pyproject.toml
Файл: pyproject.toml (в корне репо)
Статус: требует доработок/рекомендаций (non-blocking but important)

Выявленные вопросы и рекомендации:
- packages = [{ include = "src/crewai_contracts_analytics", from = "src" }]
  По документации Poetry поле include должно указывать имя пакета (module), а from — каталог. Корректная запись обычно:
    packages = [{ include = "crewai_contracts_analytics", from = "src" }]
  Текущая запись включает путь 'src/crewai_contracts_analytics' — некорректно. Это может привести к тому, что poetry не соберёт пакет правильно.
- Отсутствует poetry.lock в репозитории (Dockerfile ожидает poetry.lock* при COPY). Если вы используете Poetry вы должны зафиксировать зависимые версии в poetry.lock и закоммитить его. Без lock reproducible installs не гарантированы и Docker build может провалиться.
- Список зависимостей выглядит разумно, но:
  - Некоторые версии могли конфликтовать друг с другом по системным библиотекам (например Pillow, pdfminer, pytesseract require system packages — Dockerfile содержит установки, но CI/packaging должны учитывать это).
  - 'elasticsearch' >=8 может потребовать дополнительных extras/compatibility; при использовании OpenSearch лучше использовать opensearch-py вместо elasticsearch, либо pin конкретную версию совместимую с OpenSearch, если OpenSearch используется (в spec рекоммендован Elasticsearch/OpenSearch).
- Рекомендация: выполнить локально:
    poetry lock
    poetry install --no-dev
  и проверить, что окружение собирается. Добавить poetry.lock в репозиторий.

Патч (packages correction):
--- a/pyproject.toml
+++ b/pyproject.toml
@@
-packages = [{ include = "src/crewai_contracts_analytics", from = "src" }]
+packages = [{ include = "crewai_contracts_analytics", from = "src" }]
 
Дополнительно:
- Добавьте файл requirements.txt, сгенерированный командой:
    poetry export -f requirements.txt --output requirements.txt --without-hashes --dev
  Это упростит установку в окружениях где не используется Poetry.
- Проверьте, нужен ли python = "^3.11" — все указанные зависимости поддерживают 3.11, но тесты/CI должны проверить.

8) Dockerfile
Проблемы обнаружены и рекомендации:
- COPY pyproject.toml poetry.lock* /app/
  Если poetry.lock отсутствует в контексте, COPY с wildcard может провалиться (Docker версии и client may error if no file matches). Наиболее надёжный подход:
    - Добавить poetry.lock в репозиторий (рекомендация — зафиксировать lock).
    - Или заменить COPY на две инструкции: COPY pyproject.toml /app/ и затем COPY poetry.lock /app/ (и при отсутствии poetry.lock команда упадёт, поэтому лучше всё-таки закоммитить poetry.lock).
- RUN poetry install --no-interaction --no-ansi --no-dev
  Работает при наличии poetry и корректно настроенного pyproject. Но если вы хотите альтернативный путь (pip), добавьте requirements.txt и опцию сборки на основе pip.
- Установка системных пакетов: apt-get install включает tesseract + tesseract-ocr-rus — для некоторых окружений это увеличит размер образа. Если production не требует OCR внутри контейнера (например OCR вынесен на отдельный сервис), сделайте multi-stage или вынесите OCR в отдельный image, уменьшив базовый образ.

Рекомендация (патч-примеры):
- Обязательное: добавить poetry.lock в репозиторий.
- Dockerfile упрощение COPY:
--- a/Dockerfile
+++ b/Dockerfile
@@
-# Copy only pyproject and poetry.lock to leverage Docker cache
-COPY pyproject.toml poetry.lock* /app/
+# Copy only pyproject and poetry.lock to leverage Docker cache
+# Ensure poetry.lock is present in repo for reproducible builds.
+COPY pyproject.toml poetry.lock /app/
 
(Если вы не хотите хранить poetry.lock — замените установку зависимостей на pip + requirements.txt.)

Дополнительно:
- Добавить HEALTHCHECK или минимальный entrypoint для production.
- Рассмотреть multi-stage build, чтобы сократить размер и убрать dev-зависимости.

9) Cross-references agent ↔ task ↔ mapped_service (semantics / naming hygiene)
Найдено:
- В спецификации agents и tasks используются разные именования mapped_service (напр., "IngestionAgent" vs "ingestion-service" vs "ingestion_service"). В некоторых местах mapping_to_services используют PascalCase "IngestionAgent", в других — kebab-case "ingestion-service".
- tasks_spec.yml указывает mapped_service: ingestion-service (kebab), но mapping_to_services (deployment_map) использует ingestion_service: "IngestionAgent" (snake_case key). Это не является синтаксической ошибкой, но провоцирует ошибки интеграции при автоматической привязке (bootstrap) — автоматический связывающий код может не найти нужный агент по несовпадающему идентификатору.

Рекомендация:
- Ввести строгую машину-идентификаторную схему (например: service-id = kebab-case, agent-id = snake_case with suffix _agent) и централизованно поддерживать словарь (mapping) в одном конфигурационном файле. Пример:
    service_ids:
      ingestion-service: ingestion_agent
      parser-service: parser_agent
  и использовать этот словарь во всех модулях/CI для валидации.

10) Tests (текущие юнит‑тесты)
- tests/test_redaction.py — OK.
- tests/test_parsers.py — использует python-docx и пропускает тест при его отсутствии — это нормально.

Рекомендации по CI:
- Добавить шаги:
  - yamllint (или yaml validator) для всех YAML-файлов (включая src/.../config/*, root/*.yml).
  - python -m pytest -q
  - poetry lock & poetry install (или pip install -r requirements.txt) + run linters (mypy, black, isort)
  - security scanning (safety, pip-audit)
  - Build Docker image (ci) to catch Dockerfile / dependency install issues early.

Consolidated actionable checklist (priority order)
1. Исправить src/crewai_contracts_analytics/config/agents.yaml — критическая синтаксическая ошибка. (см. патч выше)
2. Исправить tasks_spec.yml — определить YAML anchor (&output_envelope) и заменить все alias на *output_envelope. (см. патч выше)
3. Исправить pyproject.toml packages включение (include = "crewai_contracts_analytics", from = "src") и добавить poetry.lock в репо (или поменять Dockerfile на variant без lock).
4. Править Dockerfile: убедиться, что poetry.lock доступен, либо изменить COPY и install стратегию. Добавить instructions для build arg/conditional copy, либо добавить poetry.lock.
5. В crew.py — сузить except до ImportError и добавить предупреждение (см. патч выше).
6. Уточнить и унифицировать mapped_service/service id naming across agents/tasks/deployment_map (создать centralized mapping).
7. Добавить schema/jsonschema для output artifacts (entities.json, clauses.json, risks.json), включить jsonschema-based validation в CI.
8. Добавить requirements.txt (exported from Poetry) чтобы упростить установку на окружениях без Poetry.
9. Добавить yamllint и yamllint config в CI, проверить все YAML.

Примеры «малых» утилитных патчей (уже упомянуты) — сводка/резюме diffs
- agents.yaml — убрать экранированные \n, выровнять отступы, убедиться, что каждая запись начинаeтся с "- id:" на одном и том же уровне.
- tasks_spec.yml — добавить YAML anchor &output_envelope в defaults и заменить везде использование *defaults.output_envelope на *output_envelope.
- pyproject.toml — исправить packages include значение.
- Dockerfile — убедиться в наличии poetry.lock при COPY; либо изменить COPY на COPY pyproject.toml /app/ и затем RUN poetry install (но reproducibility suffers).

Примеры команд для локальной проверки после исправлений
- yamllint .  (или yamllint -c .yamllint conf)
- python -m venv .venv && source .venv/bin/activate && pip install poetry && poetry lock && poetry install
- pytest -q
- docker build --no-cache -t crewai:dev .

Дополнительные замечания по безопасности и соответствию (security/compliance)
- Проверьте, что DataProtectionAgent вызывается программно ДО любых внешних вызовов — это описано в BR1. Добавить unit/regression tests, которые моделируют external_llm flag и проверяют, что redaction happens and redaction_log persisted.
- Audit: убедиться, что AuthAndAuditAgent пишет immutable записи в OpenSearch и что retention policy определена отдельно.
- Data localization: выделить и задокументировать конфиг для "deploy_in_russia_only" (например env ALLOW_DATA_LOCALIZATION_RU=true) и соответствующие infra instructions.

Контрольные тесты (recommended)
- Интеграционный smoke: запустить main.py после фикса agents.yaml и tasks_spec.yml; ожидать, что agents_cfg и tasks_cfg загружены и main печатает список агентов и задач.
- End-to-end pipeline unit: mock S3Client + InMemoryQueue -> publish ingestion event -> assert tasks created/queued.

Приложение: конкретные изменения (patch snippets) — повторно для быстрого копирования

A) tasks_spec.yml — добавить anchor &output_envelope и заменить alias:
(см. раздел 2 — патч)

B) src/crewai_contracts_analytics/config/agents.yaml — удалить внедрённые escaped-newline и переписать блок ClauseClassifier / RiskDetector:
(см. раздел 1 — патч)

C) pyproject.toml — исправить packages:
(см. раздел 7 — патч)

D) Dockerfile — заменить COPY и зафиксировать poetry.lock:
(см. раздел 8 — патч)

E) crew.py — ловить ImportError вместо Exception:
(см. раздел 6 — патч)

Заключение
- Первым приоритетом является исправление синтаксических ошибок YAML (agents.yaml и tasks_spec.yml). Пока эти проблемы не исправлены, автоматическая загрузка конфигураций в crew.py вернёт None/пустые структуры и это приведёт к неверной инициализации runtime.
- После исправлений рекомендую прогнать CI (yamllint + pytest + docker build) и добавить автоматизированный шаг, который проверяет: все task ids в dag.yml существуют в tasks_spec.yml, все agents declared в agents.yaml имеют уникальные id, и что mapping_to_services keys соответствуют реальным identifiers (issue ранее с inconsistent names).

Если хотите — могу:
- Сгенерировать точные полные исправленные файлы (agents.yaml и tasks_spec.yml) на основе текущей информации и вернуть diff/полные версии файлов.
- Сгенерировать .yamllint config и GitHub Actions workflow для автоматической проверки YAML и тестов.
- Помочь с генерацией poetry.lock (локально) и подготовить requirements.txt (export).

--- END validation_report.md ---

Notes: я использовал yaml_lint_validate_tool для проверки файлов: src/crewai_contracts_analytics/config/agents.yaml, src/crewai_contracts_analytics/config/tasks.yaml, tasks_spec.yml, dag.yml, llm_matrix.yml. Для pyproject.toml и Dockerfile — проблемы выявлены статическим анализом содержимого и практическими рекомендациями, поскольку yaml_lint_validate_tool специализируется на YAML.