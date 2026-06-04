# frozen_string_literal: true

# Pre-warm ActiveStorage variants (WebP + AVIF + JPEG) для existing images.
# После deploy AVIF + WebP variants первый visitor каждого record платит
# латентность libvips encoding (~200-500ms per image per variant). Эта rake
# пробегает все records одним проходом, генерируя variants на disk заранее.
#
# Idempotent — `.processed` на ActiveStorage variant skip'ит если blob уже есть.
# Безопасно запускать сколько угодно раз. Off-peak предпочтительно.
#
# Usage:
#   bundle exec rake images:prewarm                # все 3 модели
#   bundle exec rake images:prewarm:property       # только Property
#   bundle exec rake images:prewarm:article        # только Article
#   bundle exec rake images:prewarm:case_study     # только CaseStudy
#
# Через docker compose:
#   docker compose exec -T web bundle exec rake images:prewarm
namespace :images do
  # Variants per model — must match has_many_attached / has_one_attached block.
  PROPERTY_VARIANTS = %i[
    thumb thumb_webp thumb_avif
    card  card_webp  card_avif
    hero  hero_webp  hero_avif
  ].freeze

  COVER_VARIANTS = %i[
    hero hero_webp hero_avif
    og
    card card_webp card_avif
  ].freeze

  desc 'Pre-warm AVIF + WebP variants для всех Property/Article/CaseStudy images'
  task prewarm: :environment do
    started_at = Time.current
    puts "[images:prewarm] starting at #{started_at.strftime('%d.%m.%y %H:%M:%S')}"
    summary = {}
    %i[property article case_study].each do |model|
      summary[model] = prewarm_model(model)
    end
    elapsed = (Time.current - started_at).to_i
    puts ''
    puts '=== SUMMARY ==='
    summary.each do |model, stats|
      puts format('%-12s records=%-5d variants_ok=%-6d errors=%d',
                  model, stats[:records], stats[:ok], stats[:errors])
    end
    puts "elapsed: #{elapsed}s (#{(elapsed / 60.0).round(1)} min)"
  end

  namespace :prewarm do
    desc 'Pre-warm только Property images (9 variants per image)'
    task property: :environment do
      stats = Rake::Task['images:_prewarm_property'].invoke
      print_stats('property', stats)
    end

    desc 'Pre-warm только Article cover_image (7 variants per record)'
    task article: :environment do
      stats = Rake::Task['images:_prewarm_article'].invoke
      print_stats('article', stats)
    end

    desc 'Pre-warm только CaseStudy cover_image (7 variants per record)'
    task case_study: :environment do
      stats = Rake::Task['images:_prewarm_case_study'].invoke
      print_stats('case_study', stats)
    end
  end

  # Hidden tasks — реальный pre-warm. Public sub-tasks выше используют их.
  task _prewarm_property: :environment do
    @stats = prewarm_property
  end
  task _prewarm_article: :environment do
    @stats = prewarm_article
  end
  task _prewarm_case_study: :environment do
    @stats = prewarm_case_study
  end

  # ---------- helpers ----------

  def prewarm_model(model)
    case model
    when :property   then prewarm_property
    when :article    then prewarm_article
    when :case_study then prewarm_case_study
    end
  end

  def prewarm_property
    records = 0
    ok = 0
    errors = 0
    Property.where.not(images_count: 0).find_each do |property|
      next unless property.images.attached?

      records += 1
      property.images.each do |img|
        PROPERTY_VARIANTS.each do |variant|
          if process_variant(img, variant, "Property##{property.id}")
            ok += 1
          else
            errors += 1
          end
        end
      end
      progress_dot(records)
    end
    puts ''
    puts "[Property] records=#{records} ok=#{ok} errors=#{errors}"
    { records: records, ok: ok, errors: errors }
  end

  def prewarm_article
    records = 0
    ok = 0
    errors = 0
    Article.find_each do |article|
      next unless article.cover_image.attached?

      records += 1
      COVER_VARIANTS.each do |variant|
        if process_variant(article.cover_image, variant, "Article##{article.id}")
          ok += 1
        else
          errors += 1
        end
      end
      progress_dot(records)
    end
    puts ''
    puts "[Article] records=#{records} ok=#{ok} errors=#{errors}"
    { records: records, ok: ok, errors: errors }
  end

  def prewarm_case_study
    records = 0
    ok = 0
    errors = 0
    CaseStudy.find_each do |case_study|
      next unless case_study.cover_image.attached?

      records += 1
      COVER_VARIANTS.each do |variant|
        if process_variant(case_study.cover_image, variant, "CaseStudy##{case_study.id}")
          ok += 1
        else
          errors += 1
        end
      end
      progress_dot(records)
    end
    puts ''
    puts "[CaseStudy] records=#{records} ok=#{ok} errors=#{errors}"
    { records: records, ok: ok, errors: errors }
  end

  # `.processed` идемпотентен — если blob на disk есть, skip. Иначе encode.
  # rescue ловит libvips errors на повреждённых source images (corrupt JPEG/PNG)
  # — продолжаем со следующим, не падаем целиком.
  def process_variant(attachment, variant_name, ctx)
    attachment.variant(variant_name).processed
    true
  rescue StandardError => e
    Rails.logger.warn("[images:prewarm] #{ctx} variant(#{variant_name}) failed: #{e.class}: #{e.message}")
    warn "  ⚠️  #{ctx} variant(#{variant_name}) failed: #{e.class}: #{e.message.truncate(80)}"
    false
  end

  def progress_dot(n)
    print '.'
    print " #{n}\n" if (n % 50).zero?
    $stdout.flush
  end

  def print_stats(model, _stats)
    s = @stats || {}
    puts ''
    puts format('=== %s === records=%d ok=%d errors=%d', model, s[:records].to_i, s[:ok].to_i, s[:errors].to_i)
  end
end
