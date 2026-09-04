# frozen_string_literal: true

# Property делает `after_validation :geocode` на каждое изменение адреса
# (app/models/property.rb), поэтому любая фабрика объекта уходит в сеть —
# в спеках это даёт то SSLError, то случайную задержку.
#
# Ставим тестовый lookup с координатами Рязани. Один и тот же ответ на
# любой адрес: если спеку понадобятся разные координаты, он добавит свой
# `Geocoder::Lookup::Test.add_stub` на конкретный адрес.
#
# Примечание: dev/upgrade несёт похожую настройку в spec/support/
# external_services.rb вместе с WebMock.disable_net_connect!. После её
# мержа этот файл станет избыточным — обе настройки идемпотентны.
Geocoder.configure(lookup: :test, ip_lookup: :test)

Geocoder::Lookup::Test.set_default_stub(
  [
    {
      'coordinates'  => [54.6269, 39.6916],
      'address'      => 'Рязань, Россия',
      'state'        => 'Рязанская область',
      'country'      => 'Россия',
      'country_code' => 'RU'
    }
  ]
)
