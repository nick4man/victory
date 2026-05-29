# frozen_string_literal: true

# Default service catalog. Idempotent: re-running won't duplicate.
# crm_type_id is filled in later by admin via /dashboard/admin/reports
# (or via direct DB update) when Topnlab type IDs become known.
SERVICE_TYPES = [
  {
    slug: 'mortgage', title: 'Ипотека и кредитование',
    description: 'Подбор ипотечной программы, расчёт платежей, сопровождение сделки в банке. Работаем со всеми крупными банками РФ.',
    category: 'finance', icon: 'banknotes', order_position: 10,
    cta_label: 'Подобрать ипотеку',
    target_path: '/services/mortgage_calculator'
  },
  {
    slug: 'legal', title: 'Юридическое сопровождение',
    description: 'Проверка чистоты сделки, подготовка договоров, регистрация перехода права, защита интересов в суде.',
    category: 'legal', icon: 'scale', order_position: 20,
    cta_label: 'Получить консультацию'
  },
  {
    slug: 'valuation', title: 'Профессиональная оценка',
    description: 'Онлайн-оценка по медиане аналогов: 4 шага и сразу видите рыночную стоимость с диапазоном и аналогами в районе.',
    category: 'finance', icon: 'chart', order_position: 30,
    cta_label: 'Узнать стоимость',
    target_path: '/valuations/new'
  },
  {
    slug: 'inspection', title: 'Технический осмотр объекта',
    description: 'Выезд эксперта на объект перед сделкой: проверка коммуникаций, скрытых дефектов, документации БТИ.',
    category: 'technical', icon: 'clipboard', order_position: 40,
    cta_label: 'Заказать выезд'
  },
  {
    slug: 'sale_help', title: 'Помощь в продаже',
    description: 'Профессиональная фотосъёмка, размещение на топовых площадках, переговоры, организация показов.',
    category: 'marketing', icon: 'megaphone', order_position: 50,
    cta_label: 'Подать на продажу'
  },
  {
    slug: 'rent_help', title: 'Подбор арендатора',
    description: 'Проверка арендаторов, заключение договора аренды, сопровождение коммерческих и жилых объектов.',
    category: 'marketing', icon: 'key', order_position: 60,
    cta_label: 'Найти арендатора'
  }
].freeze

puts '🛠  Seeding service types...'
SERVICE_TYPES.each do |attrs|
  st = ServiceType.find_or_initialize_by(slug: attrs[:slug])
  st.assign_attributes(attrs.merge(public_visible: true, active: true))
  st.save!
end
puts "✅ #{ServiceType.count} service types"
