# A2 — SEO-слой по жилым комплексам (`/zhk`)

## Context

Задача A2 стратегического роадмапа («программные SEO landings») по районам **уже закрыта**: работает пирамида `/kupit/:type/rayon/:district` (`landings_controller.rb`, 286 строк), реестр `RyazanDistricts` (20 микрорайонов + 4 админ-района), редакционный контент по всем 20 микрорайонам для `sale × kvartira`, sitemap с per-URL `lastmod`, FAQPage/CollectionPage JSON-LD, soft-404 guard. Заводить параллельный `/districts/[slug]` нельзя — это каннибализация собственной выдачи.

Незакрытая часть A2 — **жилые комплексы**. Запросы «ЖК Легенда Рязань», «Скобелев купить квартиру», «ЖК Приокский парк цены» сейчас не ловятся ничем. Данных о ЖК в системе нет вообще: ни модели, ни колонки, ни поля в CRM-маппере (`@p['building']` у Topnlab — это номер строения, не ЖК; признак первички `is_first_sale` схлопнут в `is_featured`). Названия ЖК существуют только прозой в 5 партиалах лендингов.

Решение пользователя: **собственный справочник ЖК в БД + админка** (не эвристика по адресам, не парсинг чужих фидов, не CRM).

Итог: новый слой entity-страниц, ранжирующихся по бренд-запросам ЖК, взаимно перелинкованных с district-лендингами и карточками объектов.

> ⚠️ Этот файл лежит в `~/.claude/plans/` — глобальном каталоге с переиспользуемыми автоименами (мы уже потеряли так два документа). **Первым шагом реализации скопировать его в репозиторий** как `.claude/plans/a2-zhk-landings.md`.

## Ключевые решения

| Вопрос | Решение | Почему |
|---|---|---|
| URL | `/zhk/:slug`, не `/buildings/:slug` | Вся SEO-пирамида уже транслитерированно-русская (`/kupit/kvartira/rayon/solotcha`). Токен «zhk» совпадает с запросом и подсвечивается в выдаче. Слово `building` в репо уже занято тремя разными смыслами (`building_year`, `building_type`, `@p['building']`) |
| Не вкладывать в `/kupit/kvartira/zhk/:slug` | Отдельный namespace | Страница ЖК — сущность, а не фасет intent×type. Вложение даёт комбинаторику `2 intent × 5 типов × N ЖК` тонких дублей и распыляет ссылочный вес |
| Hub `/zhk` | Да, с гейтом ≥3 готовых ЖК | Ловит «новостройки Рязани»; единственная точка распределения веса на все ЖК |
| Имя модели | `ResidentialComplex` | `Complex` — класс ядра Ruby; `Building` — коллизия смыслов |
| Редакционный контент | `body_blocks jsonb` на самой модели | Уникальный индекс `LandingContent` — `(intent, type, district_slug, rooms)`, это оси фасета; у ЖК нет ни intent, ни type. Пятая nullable-колонка ослабит индекс (NULL в PG не конфликтуют). Плюс не повторяем хак с `premium` через слот `rooms` (`landings_controller.rb:113-116`) |
| Привязка объектов | Ручная в админке + read-only rake-подсказчик | Авто-линкер — Фаза 5 |
| Агрегаты | Новый `ListingStats`, применяется только к новому коду | Три существующих call-site трогать не будем — см. §Вне scope |

## Фазы

Жёсткое разделение сред: **seo-worktree** (`/home/q/victory-seo`, нет bundle/rails/rspec) пишет текст файлов; **victory-worktree** (`/home/q/victory-victory`) прогоняет всё, что требует рантайма. `/home/q/victory` (live-prod bind-mount) и чужие worktree не трогаем. Хендофф — `bin/claude-inbox` по `.claude/skills/session-handoff-protocol`, одно сообщение на границу фазы.

Каждая фаза — отдельный PR в `main`, CI (rubocop + brakeman + bundler-audit) + обязательный `code-reviewer` по diff.

---

### Фаза 1 — слой данных (публичного эффекта нет) → PR #1

**Пишем в seo:**
- `db/migrate/…_create_residential_complexes.rb` — таблица `residential_complexes`:
  `name` (null: false), `slug`, `city` (default 'Рязань'), `district_slug`, `developer`, `address`, `address_patterns` (string[]), `latitude`/`longitude`, `built_from`/`built_to`, `buildings_count`, `floors_min`/`floors_max`, `wall_material`, `housing_class` (enum), `build_status` (enum), `has_parking`/`has_closed_yard`/`has_playground`/`has_kindergarten`/`has_school`, `title`, `meta_description` (300), `body_blocks jsonb []`, `body_html`, `body_plain`, `published` (default false), `deleted_at`, timestamps.
  Индексы: unique на `slug`; `%i[city district_slug]`; `published`; `deleted_at`.
  Enum'ы по конвенции — `prefix: true` + русский перевод в комментарии:
  `housing_class {econom:0, comfort:1, business:2, elite:3}` (эконом/комфорт/бизнес/элит),
  `build_status {planned:0, under_construction:1, completed:2}` (проектируется/строится/сдан).
- `db/migrate/…_add_residential_complex_to_properties.rb` — `add_reference` null: true + `add_index … algorithm: :concurrently` + `add_foreign_key on_delete: :nullify`, с `disable_ddl_transaction!`. Таблица `properties` живая (Topnlab-sync каждые 30 мин) — CONCURRENTLY обязателен.
- `app/models/residential_complex.rb` — `friendly_id :name, use: %i[slugged history finders]`, транслитерация через `Property.transliterate_to_latin` (`property.rb:81`, тем же способом это делают `article.rb:111` и `case_study.rb:52`); `has_many :properties, dependent: :nullify`; `default_scope { not_deleted }` + `deleted_at`; скоупы `visible` (published), `sitemap_ready` (visible + `body_html` present), `in_district`; валидация `district_slug` против `Cities.districts_module(...)::MICRO`; `should_generate_new_friendly_id?` → false для опубликованных (слаг не ротируется при переименовании).
- `app/models/concerns/renders_landing_blocks.rb` — извлечение `before_save :rerender_caches` + тела метода из `landing_content.rb:30,50-59` дословно. `LandingContent` переводится на `include`. **Единственная правка живого прод-кода в этой фазе** → нужен регрессионный спек.
- `app/models/property.rb` — `belongs_to :residential_complex, optional: true`, `scope :in_complex`. `counter_cache` НЕ использовать: нужный счётчик — `on_site`-скоупный, а counter_cache считает и черновики, и soft-deleted.
- `db/seeds/residential_complexes.rb` + `lib/tasks/zhk.rake` (`zhk:seed`, идемпотентно через `find_or_initialize_by(slug:)`), **не** подключать в `db/seeds.rb`.
- Спеки: `spec/factories/residential_complexes.rb`, `spec/models/residential_complex_spec.rb`, `spec/models/landing_content_spec.rb` (регрессия concern-а).

**Сид — 7 ЖК из прозы лендингов** (`published: false`, фактура пустая):

| name | slug | district_slug | developer | источник |
|---|---|---|---|---|
| Приокский парк | `priokskiy-park` | `priokskiy` | Единство | `_sale_kvartira_priokskiy.html.erb:8` |
| Легенда | `legenda` | `kanishchevo` | — | `_sale_kvartira_kanishchevo.html.erb:10` |
| Видный | `vidnyy` | `semchino` | — | `_sale_kvartira_semchino.html.erb:10` |
| Метропарк | `metropark` | `semchino` | — | там же |
| Скобелев | `skobelev` | `dashkovo-pesochnya` | Единство | `_sale_kvartira_dashkovo-pesochnya.html.erb:10` |
| Открытие | `otkrytie` | `dashkovo-pesochnya` | — | там же |
| Дашково-Песочня, Старое Село 2 | `staroe-selo-2` | `dashkovo-pesochnya` | — | там же, :11 |

Годы/классы/застройщиков **не выдумывать** — проза лендингов маркетинговая, не верифицированный источник. Редактор дозаполняет по сайту застройщика / наш.дом.рф перед публикацией. «ЖК на Циолковского» (`_sale_kvartira_centr.html.erb:12`) не сидим — это оборот речи, а не название.

**victory выполняет:** `db:migrate` → dump `structure.sql` → `rspec` → `rubocop -a` → `db:rollback` + `db:migrate` (обратимость) → коммит `structure.sql`.
**Верификация перед Фазой 2:** привязать один Property к ЖК, прогнать `rake topnlab:sync`, убедиться что `residential_complex_id` уцелел. (Риск низкий — `topnlab/importer.rb:158-159` делает upsert по `(external_source, external_id)` + `assign_attributes` из whitelist маппера, без destroy — но проверить живьём.)

---

### Фаза 2 — админка → PR #2

- `app/controllers/admin/residential_complexes_controller.rb` — калька `admin/landing_contents_controller.rb` (`include AdminTokenAuth`, `assign_body_blocks_from_form`), index с coverage-картой (нет body / нет фото / нет объектов) по образцу `:30-33`.
- `app/views/admin/residential_complexes/{index,new,edit,_form}.html.erb`.
- Извлечение блок-редактора: `admin/landing_contents/_form.html.erb:122-319` (~200 строк inline JS, завязан на id `lc-blocks-json` и имя `landing_content[body_blocks_json]`) → `app/views/admin/shared/_block_editor.html.erb` с locals `param_name:`, `field_id:`, `upload_url:`. **Самая рискованная правка фазы** — обязателен ручной smoke старого редактора после.
- Роуты в существующем `namespace :admin` рядом с `resources :landing_contents` (`routes.rb:657`).
- UI привязки объектов: селект на форме объекта + блок «кандидаты» на экране ЖК (непривязанные `on_site` того же района, чекбоксы).
- `app/services/zhk/attachment_suggester.rb` + `rake 'zhk:suggest[legenda]'` — read-only, ничего не пишет. Фильтр района **обязательно** через `RyazanDistricts.aliases_for(slug)` — `district` хранит free-text алиас, прямой `where(district: slug)` не сработает никогда.
- `spec/requests/admin/residential_complexes_spec.rb`.

Мержится отдельно: админка за токеном и отдаёт `X-Robots-Tag: noindex, nofollow`. **После мержа редактор наполняет 5-7 ЖК фактурой и текстом** — это гейт Фазы 3.

---

### Фаза 3 — публичные страницы → PR #3

- Роуты после блока лендингов, до `resources :properties`:
  ```ruby
  get '/zhk',     to: 'residential_complexes#index', as: :zhk_index
  get '/zhk/:id', to: 'residential_complexes#show',  as: :zhk,
                  constraints: { id: %r{[a-z0-9-]+} }
  ```
- `app/controllers/residential_complexes_controller.rb`. Берём из эталона `landings_controller.rb`: `expires_in 15.minutes, public: true` (:70), `render_not_found` через `render template: 'errors/not_found', status: :not_found` (:164-167 — НЕ `raise RoutingError`, комментарий «Yandex penalises soft-404s»), `add_breadcrumb` (:122-123).
  **Делаем иначе:** `build_scope` в эталоне пересобирается 4× за запрос (:101-103, :233, :251) — здесь мемоизированный `listings_scope` + один вызов `ListingStats`.
  Плюс явный `redirect_to zhk_path(@complex), status: :moved_permanently` при `params[:id] != @complex.slug` (friendly_id `history` резолвит старые слаги).
- `app/controllers/concerns/renders_not_found.rb` — извлечь `render_not_found` и подключить в `LandingsController` тоже (третий потребитель оправдывает вынос).
- `app/services/listing_stats.rb` — `ListingStats.for(scope) → Result(count, min_price, max_price, avg_price_per_sqm, min_area, max_area)`, **один** SQL через `pick` с шестью отдельными `Arel.sql(...)`-аргументами. Ловушка: одна Arel-строка с запятыми вернёт только первую колонку — Rails считает столбцы по числу аргументов.
- `app/helpers/zhk_helper.rb` — форматирование чисел теми же правилами, что `landings_controller.rb:240,257` (min вниз до 100 тыс., avg до тысяч), `alt_for_zhk_photo` по образцу `landings_helper.rb:33`, `apartment_complex_jsonld(...) → Hash` (именно Hash, чтобы композировать в `@graph`; партиал значение не вернёт).
- `app/views/residential_complexes/{index,show}.html.erb` — порядок блоков калькой с `landings/show.html.erb`: `content_for :title`/`:seo_description` (:1-2), canonical НЕ переопределяем (`canonical_url` в `application_helper.rb:54` срежет query сам), geo.* (:13-18), автодискавери фото (:24-29), OG-precedence (:31-38), `content_for :head` (в layout нет блока `:jsonld`, только `:head` — `application.html.erb:104`), breadcrumb, hero+H1+статистика, слайдер, фактурная карточка, `raw body_html`, перелинковка, сетка `properties/property_card` (:163-183), empty-state (:184-196), «Полезные сервисы» (:204-222).
- JSON-LD одним `@graph`: `ApartmentComplex` (подтип Residence — точнее, чем Place; `numberOfAvailableAccommodationUnits`, `amenityFeature[]` из has_*, `additionalProperty[]` для застройщика/года/класса) + `CollectionPage`+`ItemList` (форма из `landings/show.html.erb:80-95`, связать через `about`) + `BreadcrumbList` (`breadcrumb_jsonld`, `application_helper.rb:26` — возвращает raw JSON без `<script>`) + отдельным тегом `FAQPage` (`faq_jsonld(faq_pairs_from_html(body_html))` — `render_faq_block` уже эмитит `<details><summary>`, так что FAQ достаётся бесплатно) + `ImageObject` (`shared/_jsonld_image_object`).
- Фото: `public/images/zhk/<slug>/` (`hero.jpg`, `*.jpg`, `og.jpg` 1200×630 исключается из слайдера) — дословно district-конвенция. Ровно один eager: есть hero → `shared/_photo_slider` уже ставит `fetchpriority=high` только на `i.zero?` (:55-56); нет hero → `priority_image: true` первой карточке сетки (`_property_card.html.erb:4-7`). Условия взаимоисключающие — записать одним тернарником.
- Спеки: `spec/requests/zhk_spec.rb`, `zhk_hub_spec.rb`, `spec/services/listing_stats_spec.rb`.

**Soft-404 guard — сознательно отличается от district-лендингов.** У лендингов `noindex,follow` при `@total_count.zero?` (`landings/show.html.erb:73-75`). У ЖК noindex только когда `count.zero? И body_html.blank?`: нулевой остаток объектов — штатное состояние (продались), но страница с фактурой и текстом обязана ранжироваться по «ЖК Легенда» именно тогда, когда инвентаря нет — в этом весь смысл фичи. Условие инкапсулировать как `ResidentialComplex#indexable?` и **переиспользовать в sitemap** — расхождение sitemap/robots это классическая причина демоции в Яндексе.

**Гейт мержа:** ≥3 ЖК на проде с `sitemap_ready == true`. Перед мержем — прогон `.claude/skills/victory-seo-checklist` (10 пунктов) по обоим шаблонам.

---

### Фаза 4 — перелинковка и индексация → PR #4

Намеренно последняя: не гоним краулеров на страницы раньше, чем они станут хорошими.

| Направление | Где |
|---|---|
| District-лендинг → ЖК района | новый `app/views/shared/_landing_complexes.html.erb`, врезка в `landings/show.html.erb` после `_landing_neighbors` (:158-160); guard на пустой результат; `cache ['landing_complexes/v1', complexes]` |
| ЖК → район | `buy_district_landing_path(type: 'kvartira', district: …)` + уровень района в крошках |
| ЖК → ЖК | «Другие ЖК района» + «Другие ЖК застройщика», cap 6 |
| Карточка объекта → ЖК | `properties/show.html.erb` рядом с `_show_district_cluster` (:163-165) + `containedInPlace` в существующий JSON-LD. **Только на show, не в `_property_card`** — карточка рендерится в десятках сеток, обращение к ассоциации даст N+1 во всех этих контроллерах |
| Футер → hub | `shared/_site_footer.html.erb`. Мега-меню хедера не трогаем |

- Sitemap: секция в `app/views/sitemap/pages.xml.erb` после district-блока (:62-78), правило публикации зеркалит :54-58 («без собственного контента в sitemap не включаем») с поправкой: наличие объектов **не требуется**, требуется `body_html`. Priority 0.7 / weekly.
  **lastmod без N+1**: `district_lastmod` (`sitemap_helper.rb:23`) делает SQL на каждый URL — усугублять нельзя. Предрасчёт в `SitemapController#pages` (сейчас тело пустое, `respond_to(&:xml)`, :22-24): загрузить `sitemap_ready` + один `group(:residential_complex_id).maximum(:updated_at)`. Два запроса на всю секцию независимо от числа ЖК.
- IndexNow + Я.recrawl: `after_commit` на модели по образцу `property.rb:251-258 → :1006-1030`, условие — publish-переход / смена `body_html` / переименование. Джобы существующие (`Seo::IndexNowNotifyJob`, `Yandex::RecrawlUrlJob`), оба сервиса сами скипают вне production.
  **Явно НЕ уведомляем при привязке объекта** — квота Я.Вебмастера 150/день, а привязок при наполнении будут сотни; им достаточно sitemap `lastmod`. Записать решение комментарием в модели.
- `lib/tasks/yandex_webmaster.rake:69-79` — добавить `/zhk` в `recrawl:critical` (таск уже проверяет квоту перед отправкой).
- `robots.txt` правок не требует — проверить глазами heredoc на отсутствие совпадающего `Disallow`.
- `spec/requests/sitemap_spec.rb`.

**После мержа:** `rake yandex:webmaster:recrawl:critical`, через 3-4 недели — отчёт по запросам (`.claude/skills/yandex-webmaster-api-patterns`).

## Verification

**Фаза 1 (victory):** миграции применяются и откатываются чисто; `rake zhk:seed` идемпотентен (второй прогон — 0 изменений); `rspec spec/models/` зелёный, включая регрессию `landing_content_spec`; после `rake topnlab:sync` привязка `residential_complex_id` жива.

**Фаза 2:** `/admin/residential_complexes?token=…` → 200, без токена → редирект; создание ЖК с блоками всех 7 kind-ов → `body_html`/`body_plain` заполнены; **ручной smoke `/admin/landing_contents/:id/edit`** после извлечения блок-редактора.

**Фаза 3:**
- `/zhk/legenda` → 200, один `<h1>`, canonical без query, `Cache-Control: max-age=900, public`;
- `/zhk/nesushchestvuyushchiy` → HTTP **404** с шаблоном `errors/not_found` (не 200, не RoutingError);
- заход по историческому слагу → **301** на канонический;
- `noindex,follow` присутствует при `count==0 && body_html.blank?` и **отсутствует** при непустом body с нулём объектов;
- ровно один `fetchpriority="high"` в HTML;
- Rich Results Test + validator.schema.org без ошибок; `@graph` содержит `ApartmentComplex` и `BreadcrumbList`;
- Lighthouse SEO ≥ 85, LCP < 2.5s.

**Фаза 4:** `/sitemap-pages.xml` содержит hub и только `sitemap_ready` ЖК; число SQL по секции ЖК не растёт с числом ЖК (спек через `ActiveSupport::Notifications`); district-лендинг показывает блок ЖК и не показывает пустой заголовок при их отсутствии.

## Риски

1. **Каннибализация с district-лендингами.** «купить квартиру в Канищево» остаётся за district-лендингом, «ЖК Легенда» — за `/zhk/legenda`. H1/title ЖК начинаются с бренда, никогда с родовой формулы; анкоры взаимных ссылок различны. Контроль — отчёт Я.Вебмастера через 3-4 недели; если ЖК-URL забирает показы по районным запросам, ужесточить title.
2. **Каннибализация с карточкой объекта** (ЖК с единственным листингом). Снимается правилом индексации: без собственного body — `noindex,follow`.
3. **Тонкие страницы / soft-404.** `published` по умолчанию false; `sitemap_ready` требует `body_html`; guard и sitemap используют одно выражение; hub перечисляет только `sitemap_ready`; старт ограничен 5-7 ЖК с рукописным текстом.
4. **Дубли контента между ЖК одного застройщика** — классическая смерть программного SEO. Авто-генерация текста запрещена; каждый ЖК несёт ≥2 уникальных факта; в админ-index предупреждение при совпадении первого абзаца `body_plain`; конвенция — в `app/views/residential_complexes/README.md` по образцу `app/views/landings/content/README.md`; копирайт через `.claude/skills/russian-real-estate-copywriting`.
5. **Стабильность слагов как публичных URL** (`ryazan_districts.rb:16-17` прямо предупреждает, что смена слага — вопрос 301). Три уровня: friendly_id `history`, `should_generate_new_friendly_id? == false` для опубликованных, явный 301 в контроллере (покрыт спеком).
6. **Регрессия блок-редактора** при извлечении общего партиала — ручной smoke обязателен в PR #2.
7. **Выжигание квоты Я.recrawl** — колбэк не срабатывает на привязку объектов (см. Фазу 4).
8. **Достоверность фактов** (застройщик, сроки, класс) — сид оставляет поля пустыми, заполнение только после сверки с официальным источником.

## Вне scope (зафиксировать, не делать)

- Авто-линкер Property→ЖК на Topnlab-синке.
- Адаптация `ListingStats` в `LandingsController` / `PropertiesController#build_facet_counts` (:495-517) / `Llm::ChatResponder:90`. Агрегатная логика продублирована в 4 местах, но у них разные формы запроса, разное форматирование и разная обработка ошибок — правка трёх горячих прод-путей ради нулевого пользовательского эффекта. Оставить `# TODO(refactor): adopt ListingStats`, вынести отдельным тикетом.
- Загрузка фото ЖК через ActiveStorage (пока файловая конвенция, как у районов).
- Аренда в ЖК как отдельный URL-фасет.
- ЖК в `_property_card` (нужен корректный `includes` во всех сетках).
- Чат-тул `GetComplexContent` поверх `body_plain`.
- Мультигород (`/moskva/zhk/…`) — у Москвы и СПб `district` не заполнен вовсе.
