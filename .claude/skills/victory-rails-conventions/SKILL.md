---
name: victory-rails-conventions
description: Use when writing or refactoring Ruby/Rails code in the victory62 project. Captures the project's coding conventions (enums, soft-delete, frozen strings, single quotes, RuboCop rules, dd.MM.yy date format, service-object pattern) so generated code passes lint and matches existing style.
---

# Victory62 Rails Conventions

Применяй ВСЕ правила одновременно. Источник правды — `.claude/memory/systemPatterns.md`.

## File header

Каждый `.rb` файл начинается с:

```ruby
# frozen_string_literal: true
```

## String literals

**Single quotes** для строк без интерполяции. Double quotes только когда `"#{var}"` или escape (`"\n"`).

```ruby
name = 'Иван'              # ✓
greeting = "Привет, #{name}" # ✓ (interpolation)
title = "Quote\"inside"    # ✓ (escape)
title = 'Two "quotes"'     # ✓ (literal "quotes")
```

## Enums

**Всегда** с `_prefix: true`. Русский перевод в комментарии справа:

```ruby
enum status: {
  draft: 0,      # черновик
  pending: 1,    # на модерации
  active: 2,     # активный
  sold: 3,       # продано
  rented: 4,     # сдано
  archived: 5,   # архив
  rejected: 6    # отклонён
}, _prefix: true
```

Использование: `property.status_active?`, `property.status_draft!`, `Property.status_active.where(...)`

## Soft delete

Колонка `deleted_at` + `default_scope { not_deleted }`. **Никакого** `paranoia` gem.

```ruby
class Property < ApplicationRecord
  default_scope { not_deleted }
  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :only_deleted, -> { where.not(deleted_at: nil) }

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end
end

# доступ к удалённым — unscoped:
Property.unscoped.where(...)
```

## Service objects

Plain Ruby класс с `initialize` + `call`. Возвращает Result-hash или domain-object.

```ruby
# app/services/property_publisher.rb
# frozen_string_literal: true

class PropertyPublisher
  Result = Struct.new(:ok?, :value, :error, keyword_init: true)

  def initialize(property, current_user: nil)
    @property = property
    @current_user = current_user
  end

  def call
    return failure('not_draft') unless @property.status_draft?
    return failure('no_images') if @property.images.empty?

    @property.update!(status: :active, published_at: Time.current)
    Result.new(ok?: true, value: @property)
  rescue StandardError => e
    failure(e.message)
  end

  private

  def failure(error)
    Result.new(ok?: false, error: error)
  end
end

# вызов:
result = PropertyPublisher.new(property).call
return render_error(result.error) unless result.ok?
```

## Scopes

Lambda syntax, chain-safe:

```ruby
scope :published,  -> { where(status: :active).where.not(published_at: nil) }
scope :for_sale,   -> { where(deal_type: :sale) }
scope :by_price,   ->(direction = :asc) { order(price: direction) }
```

## RuboCop limits (`.rubocop.yml` already configured)

- **Target Ruby**: 3.2
- **Max line length**: 120
- **Max method length**: 25 lines
- **`rubocop-rails`, `rubocop-rspec`, `rubocop-performance`** plugins активны

Перед коммитом: `bundle exec rubocop -a` (safe autocorrect).

## Даты в коде/UI/сообщениях

**Европейский `dd.MM.yy`**. Не ISO, не US.

```ruby
date.strftime('%d.%m.%y')           # 13.05.26
I18n.l(date, format: '%d.%m.%y')

# в Active Storage filenames можно YYYY_MM_DD для сортировки
file_name = "audit_#{Date.today.strftime('%Y_%m_%d')}.pdf"
```

В UI-helper:
```ruby
# app/helpers/date_format_helper.rb
def short_date(date)
  return '—' if date.blank?
  l(date, format: '%d.%m.%y')
end
```

## Localization

Все user-facing строки через `I18n.t()`. Default locale `:ru`.

```ruby
# bad:
flash[:notice] = 'Объект опубликован'

# good:
flash[:notice] = t('properties.publish.success')
# config/locales/ru.yml:
# ru:
#   properties:
#     publish:
#       success: 'Объект опубликован'
```

## Money

`decimal` columns, never `float`. Format только через helper:

```ruby
# bad:
"#{property.price} ₽"
number_to_currency(property.price)

# good:
property.price_formatted   # → "3 500 000 ₽"
```

`price_formatted` живёт на модели:

```ruby
def price_formatted
  ActionController::Base.helpers.number_with_delimiter(price.to_i, delimiter: ' ') + ' ₽'
end
```

## Section headers

В крупных моделях/сервисах:

```ruby
class Property < ApplicationRecord
  # ============================================
  # EXTENSIONS
  # ============================================
  include FriendlyId
  ...

  # ============================================
  # ASSOCIATIONS
  # ============================================
  belongs_to :user, optional: true
  ...

  # ============================================
  # SCOPES
  # ============================================
  ...
end
```

## Auth (важно — Devise отключен)

`current_user` → `nil`, `user_signed_in?` → `false`. **Не предполагай юзера**.

Admin доступ через query-param token:

```ruby
class Admin::ReviewsController < ApplicationController
  include AdminTokenAuth  # checks ?token=ENV['ADMIN_TOKEN']

  def index
    @reviews = Review.unscoped.order(created_at: :desc)
  end
end
```

## Database conventions

- PK: `bigint` (Rails default)
- Index на каждом FK и enum-колонке
- Money: `decimal(15, 2)`, не `float`
- Settings: `jsonb` (User.notification_settings, .preferences)
- Geo: PostGIS `earth_distance` / `ll_to_earth` через raw SQL

## What NOT to do

- ❌ `current_user` без guard — Devise отключен
- ❌ `paranoia` / `discard` gems — у нас свой soft-delete
- ❌ Number formatting вручную в views — используй `*_formatted` методы
- ❌ `puts` для debug — `Rails.logger.info` или `Rails.logger.debug`
- ❌ `Time.now` — используй `Time.current` (timezone-aware)
- ❌ `Date.today` — лучше `Time.current.to_date` или хотя бы документируй timezone

## When in doubt

Прочитай `.claude/memory/systemPatterns.md` или `.claude/memory/techContext.md` для полной картины.
