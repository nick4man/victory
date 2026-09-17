# frozen_string_literal: true

module Kpi
  # BOTTLENECK — воронка показов для недельной сводки директора и /objections.
  #
  # Определения (в проекте уже четыре разных «конверсии» — здесь пятая, и она
  # намеренно другая):
  #   показ       — ShowReport.status_confirmed по conducted_at
  #   когорта     — LeadEvent.real с first_show_at в окне cohort (8 недель)
  #   конверсия   — доля лидов когорты с contract_at, считается ТОЛЬКО в ячейке
  #                 «сегмент × кто показывал»; сводной цифры по людям нет
  #                 специально — агенту по построению достаются худшие лиды
  #                 (reglament/BOTTLENECK.md, «Selection bias»)
  #   кто показывал — роль conducted_by первого подтверждённого показа лида
  #
  # KPI по объектам, а не по людям: при трёх сотрудниках персональные проценты — шум.
  class ShowFunnel
    Result = Struct.new(:week_shows, :matrix, :objects, :unreported, keyword_init: true)

    CONDUCTORS = ['руководитель', 'агент'].freeze
    UNKNOWN_SEGMENT = 'не указан'
    STUCK_SHOWS = 3

    def self.objections_summary(property:)
      reports = ShowReport.status_confirmed.for_property(property).to_a
      tags = reports.flat_map(&:objections_list).tally.sort_by { |tag, n| [-n, tag] }
      {
        shows: reports.size,
        objections: tags,
        outcomes: reports.map(&:outcome).tally,
        offered_prices: reports.filter_map(&:offered_price).map(&:to_i).sort
      }
    end

    def initialize(week:, cohort: (week.end - 8.weeks)..week.end)
      @week = week
      @cohort = cohort
    end

    def call
      Result.new(week_shows: ShowReport.confirmed_in(@week).count,
                 matrix: matrix, objects: objects, unreported: unreported_count)
    end

    def render_html
      res = call
      lines = ["🏠 <b>Показы за неделю: #{res.week_shows}</b>  · показов без отчёта: #{res.unreported}", '']
      lines << "<b>Показ → договор, когорта #{Formatters::DateFormat.fmt(@cohort.begin)}–#{Formatters::DateFormat.fmt(@cohort.end)}</b>"
      res.matrix.each do |segment, by|
        cells = CONDUCTORS.map { |c| "#{c}: #{cell(by[c])}" }.join(' · ')
        lines << "  #{segment_title(segment)} — #{cells}"
      end
      lines << '<i>Сравнивать только внутри сегмента: агенту достаются холодные лиды по построению. ' \
               'Меньше 5 показов в ячейке — не разница, а шум.</i>'
      lines << ''
      lines << '<b>Объекты</b>'
      lines << "  без показов 30 дней: #{res.objects[:no_shows_30d].size}"
      lines << "  медиана дней от публикации до первого показа: #{res.objects[:median_days_to_first_show] || '—'}"
      lines << "  ≥#{STUCK_SHOWS} показов без договора: #{res.objects[:stuck].size}#{stuck_suffix(res.objects[:stuck])}"
      lines.join("\n")
    end

    private

    def cohort_leads
      @cohort_leads ||= LeadEvent.real.where(first_show_at: @cohort).includes(:show_reports).to_a
    end

    def matrix
      rows = Hash.new { |h, k| h[k] = CONDUCTORS.to_h { |c| [c, { shows: 0, contracts: 0 }] } }
      LeadEvent::SEGMENTS.each { |s| rows[s] }
      rows[UNKNOWN_SEGMENT]
      cohort_leads.each do |lead|
        first = lead.show_reports.select(&:status_confirmed?).min_by(&:conducted_at)
        next unless first

        cell = rows[lead.segment || UNKNOWN_SEGMENT][first.conducted_by_director? ? 'руководитель' : 'агент']
        cell[:shows] += 1
        cell[:contracts] += 1 if lead.contract_at.present?
      end
      rows
    end

    def objects
      confirmed = ShowReport.status_confirmed
      shown_recently = confirmed.where(conducted_at: 30.days.ago..).where.not(property_id: nil).select(:property_id)
      no_shows = Property.in_advertising.where.not(id: shown_recently).pluck(:id)

      by_property = cohort_leads.select(&:property_id).group_by(&:property_id)
      days = by_property.filter_map do |pid, leads|
        published = Property.unscoped.find_by(id: pid)&.published_at
        next unless published

        ((leads.map(&:first_show_at).min - published) / 1.day).floor
      end

      stuck = confirmed.where.not(property_id: nil).group(:property_id).having('COUNT(*) >= ?', STUCK_SHOWS).pluck(:property_id)
      stuck -= LeadEvent.real.where.not(contract_at: nil).where(property_id: stuck).distinct.pluck(:property_id)

      { no_shows_30d: no_shows, median_days_to_first_show: median(days), stuck: stuck }
    end

    # В шапке сводки цифра стоит рядом с «показы за неделю», значит и считаться
    # должна за неделю. Без границы она включала всю историю показов агентства
    # (миграция бэкфиллит first_show_at из stage_history) и могла только расти
    # (найдено ревью PR #65).
    def unreported_count
      LeadEvent.real.where(first_show_at: @week.begin..24.hours.ago)
               .where.not(id: ShowReport.status_confirmed.select(:lead_event_id)).count
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
    end

    def cell(c)
      return '—' if c[:shows].zero?

      "#{c[:contracts]}/#{c[:shows]} (#{(c[:contracts] * 100.0 / c[:shows]).round}%)"
    end

    def segment_title(segment)
      LeadEvent::SEGMENT_LABELS[segment] || "❔ #{segment}"
    end

    def stuck_suffix(ids)
      return '' if ids.empty?

      " — #{ids.first(5).map { |id| "##{id}" }.join(', ')}"
    end
  end
end
