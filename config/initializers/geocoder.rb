# frozen_string_literal: true

# Defaults for the `geocoder` gem (used by Property#geocoded_by, MlsListing#reverse_geocoded_by,
# and the `near` scope). Address-to-coordinates lookups for PropertyValuation
# go through Geocoding::AddressLookup which has its own DaData/Yandex stack and
# does NOT use this configuration.
Geocoder.configure(
  units:    :km,
  language: 'ru',
  timeout:  5
)
