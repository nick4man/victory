# frozen_string_literal: true

module Zhk
  # Расхождение — это запрос к фактам, а не хранимая сущность: отдельная
  # таблица держала бы производное состояние, которое разъезжается первым.
  #
  # Что считаем расхождением, а что шумом:
  #
  #   * `value: nil` — источник промолчал (поля не было в его данных), это
  #     отсутствие мнения, а не мнение «данных нет». Такую строку вообще
  #     не рассматриваем: сравнивать нечего, и она не должна ни превращать
  #     единственное реальное мнение в расхождение, ни попадать в `all`
  #     как «версия» поля. Пустая строка (в отличие от nil) — источник
  #     осмотрел поле и явно заявил пустоту; это утверждение, и оно может
  #     конфликтовать с непустым значением другого источника — считаем.
  #   * Одно и то же значение, по-разному отформатированное источником, —
  #     не расхождение: регистр («Монолитно-кирпичный» / «монолитно-
  #     кирпичный»), организационно-правовая форма застройщика («ГК
  #     Единство» / «Единство»), года со служебным суффиксом («2026» /
  #     «2026 г.»). Сравниваем НЕ сырые строки, а их нормализованную форму
  #     — см. `normalize`.
  #   * Если по полю высказался ровно один источник — расхождения нет по
  #     определению (не с чем спорить), и это следует из общей проверки
  #     «более одного различного нормализованного значения», а не из
  #     отдельной ветки — так надёжнее: спорных источников может быть и
  #     трое, где двое совпали, а третий один против них.
  #
  # Строгость — не как у Matcher: там лишнее совпадение опаснее
  # пропущенного (склеит разные объекты), здесь наоборот — пропущенное
  # расхождение хуже лишнего (молча применённая неверная фактура против
  # лишней ручной работы редактора). При сомнении нормализация НЕ
  # добавляется — расхождение остаётся видимым.
  module Discrepancies
    # Организационно-правовые формы, которые не меняют застройщика по
    # существу — снимаем префиксом. Список короткий и явный намеренно:
    # угадывать сокращения было бы тем самым риском «нормализовали лишнее
    # и потеряли настоящее расхождение».
    ORG_FORM_RX = /\A(?:гк|ооо|зао|оао|пао|ип|ао)\.?\s+/i

    module_function

    # @return [Array<String>] поля этого ЖК, по которым источники спорят
    def fields_for(complex)
      facts_by_field(ZhkFact.where(residential_complex_id: complex.id))
        .select { |_, facts| discrepant?(facts) }
        .keys
        .sort
    end

    # @return [Array<Hash>] для экрана админки, по всем ЖК сразу
    def all
      facts_by_complex_and_field(ZhkFact.all)
        .filter_map do |(_complex_id, field), facts|
          next unless discrepant?(facts)

          {
            complex: facts.first.residential_complex,
            field: field,
            values: facts.map do |f|
              { value: f.value, source: f.source, url: f.url, observed_at: f.observed_at }
            end
          }
        end
        .sort_by { |row| [row[:complex]&.id.to_i, row[:field]] }
    end

    # @return [Boolean] спорит ли набор фактов одного поля между собой
    def discrepant?(facts)
      facts.map { |f| normalize(f.field, f.value) }.uniq.size > 1
    end
    private_class_method :discrepant?

    # @return [String] значение, приведённое к виду, годному для сравнения
    # (НЕ для сохранения — это чисто сравнение, сырое значение в `all` не
    # трогаем).
    def normalize(field, value)
      v = value.to_s.strip.gsub(/\s+/, ' ').downcase

      case field.to_s
      when 'developer'
        v = v.sub(ORG_FORM_RX, '')
      when 'built_from', 'built_to'
        # источники пишут год то голым числом, то с припиской «г.»/«год» —
        # для сравнения важны только цифры
        digits = v[/\d+/]
        v = digits if digits
      end

      v
    end
    private_class_method :normalize

    def facts_by_field(scope)
      scope.where.not(value: nil).group_by(&:field)
    end
    private_class_method :facts_by_field

    def facts_by_complex_and_field(scope)
      scope.where.not(value: nil)
           .includes(:residential_complex)
           .group_by { |f| [f.residential_complex_id, f.field] }
    end
    private_class_method :facts_by_complex_and_field
  end
end
