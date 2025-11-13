// app/javascript/controllers/yandex_map_controller.js
// Stimulus controller for Yandex Maps integration
// Handles map initialization, markers, clustering, and property display

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container"]
  
  static values = {
    latitude: Number,
    longitude: Number,
    zoom: { type: Number, default: 12 },
    title: String,
    price: String,
    properties: { type: Array, default: [] },
    clustered: { type: Boolean, default: true },
    interactive: { type: Boolean, default: true }
  }

  connect() {
    console.log("Yandex Map controller connected")
    
    // Wait for Yandex Maps API to load
    if (typeof ymaps === 'undefined') {
      this.loadYandexMapsAPI()
    } else {
      this.initializeMap()
    }
  }

  disconnect() {
    if (this.map) {
      this.map.destroy()
      this.map = null
    }
  }

  // ============================================
  // API LOADING
  // ============================================

  loadYandexMapsAPI() {
    const apiKey = document.querySelector('meta[name="yandex-maps-api-key"]')?.content || ''
    const script = document.createElement('script')
    
    script.src = `https://api-maps.yandex.ru/2.1/?apikey=${apiKey}&lang=ru_RU`
    script.async = true
    script.onload = () => this.initializeMap()
    script.onerror = () => {
      console.error('Failed to load Yandex Maps API')
      this.showError('Не удалось загрузить карту')
    }
    
    document.head.appendChild(script)
  }

  // ============================================
  // MAP INITIALIZATION
  // ============================================

  initializeMap() {
    ymaps.ready(() => {
      try {
        this.createMap()
        this.addContent()
      } catch (error) {
        console.error('Map initialization error:', error)
        this.showError('Ошибка инициализации карты')
      }
    })
  }

  createMap() {
    const container = this.hasContainerTarget ? this.containerTarget : this.element
    
    this.map = new ymaps.Map(container, {
      center: [this.latitudeValue || 55.7558, this.longitudeValue || 37.6173],
      zoom: this.zoomValue,
      controls: ['zoomControl', 'fullscreenControl', 'geolocationControl']
    }, {
      suppressMapOpenBlock: true,
      yandexMapDisablePoiInteractivity: true
    })

    // Add traffic control if interactive
    if (this.interactiveValue) {
      this.map.controls.add('trafficControl')
      this.map.controls.add('typeSelector')
      this.map.controls.add('routeButtonControl')
    }

    // Disable scroll zoom by default on mobile
    if (this.isMobile()) {
      this.map.behaviors.disable('scrollZoom')
    }
  }

  // ============================================
  // CONTENT ADDITION
  // ============================================

  addContent() {
    if (this.propertiesValue && this.propertiesValue.length > 0) {
      // Multiple properties - show all on map
      this.addMultipleProperties()
    } else if (this.latitudeValue && this.longitudeValue) {
      // Single property - show single marker
      this.addSingleProperty()
    }
  }

  addSingleProperty() {
    const placemark = new ymaps.Placemark(
      [this.latitudeValue, this.longitudeValue],
      {
        balloonContentHeader: this.titleValue || 'Объект недвижимости',
        balloonContentBody: this.createSinglePropertyBalloon(),
        balloonContentFooter: this.priceValue ? `<strong>${this.priceValue}</strong>` : '',
        hintContent: this.titleValue || 'Объект недвижимости'
      },
      {
        preset: 'islands#redDotIcon',
        iconColor: '#DC2626'
      }
    )

    this.map.geoObjects.add(placemark)
    
    // Open balloon by default
    placemark.balloon.open()
  }

  addMultipleProperties() {
    const geoObjects = []

    this.propertiesValue.forEach(property => {
      if (property.coordinates && property.coordinates.lat && property.coordinates.lng) {
        const placemark = this.createPropertyPlacemark(property)
        geoObjects.push(placemark)
      }
    })

    if (geoObjects.length === 0) {
      console.warn('No properties with valid coordinates found')
      return
    }

    // Add clustering if enabled and many properties
    if (this.clusteredValue && geoObjects.length > 10) {
      const clusterer = new ymaps.Clusterer({
        preset: 'islands#redClusterIcons',
        clusterDisableClickZoom: false,
        clusterOpenBalloonOnClick: true,
        clusterBalloonContentLayout: 'cluster#balloonCarousel',
        clusterBalloonPagerSize: 5,
        clusterBalloonContentLayoutWidth: 300,
        clusterBalloonContentLayoutHeight: 200
      })

      clusterer.add(geoObjects)
      this.map.geoObjects.add(clusterer)
    } else {
      // Add all markers without clustering
      geoObjects.forEach(placemark => {
        this.map.geoObjects.add(placemark)
      })
    }

    // Fit map bounds to show all properties
    this.fitBounds(geoObjects)
  }

  createPropertyPlacemark(property) {
    const coords = [property.coordinates.lat, property.coordinates.lng]
    
    const placemark = new ymaps.Placemark(
      coords,
      {
        balloonContentHeader: `<a href="${property.url}" class="font-bold text-blue-600 hover:text-blue-800">${property.title}</a>`,
        balloonContentBody: this.createPropertyBalloon(property),
        balloonContentFooter: `<strong class="text-lg text-primary-600">${property.price_formatted || property.price}</strong>`,
        hintContent: `${property.title} - ${property.price_formatted || property.price}`
      },
      {
        preset: this.getMarkerPreset(property),
        iconColor: this.getMarkerColor(property)
      }
    )

    // Track balloon open
    placemark.events.add('balloonopen', () => {
      this.trackEvent('map_balloon_opened', { property_id: property.id })
    })

    return placemark
  }

  // ============================================
  // BALLOON CONTENT
  // ============================================

  createSinglePropertyBalloon() {
    return `
      <div class="p-2">
        <p class="text-sm text-gray-600 mb-2">Расположение объекта на карте</p>
        <div class="text-xs text-gray-500">
          Координаты: ${this.latitudeValue.toFixed(6)}, ${this.longitudeValue.toFixed(6)}
        </div>
      </div>
    `
  }

  createPropertyBalloon(property) {
    let html = '<div class="py-2" style="max-width: 280px;">'
    
    // Image
    if (property.image_url) {
      html += `
        <img src="${property.image_url}" 
             alt="${property.title}" 
             class="w-full h-32 object-cover rounded mb-2"
             style="width: 100%; height: 128px; object-fit: cover; border-radius: 4px; margin-bottom: 8px;">
      `
    }
    
    // Property details
    html += '<div class="space-y-1" style="margin-top: 8px;">'
    
    if (property.rooms) {
      html += `<p class="text-sm"><strong>Комнат:</strong> ${property.rooms}</p>`
    }
    
    if (property.area) {
      html += `<p class="text-sm"><strong>Площадь:</strong> ${property.area} м²</p>`
    }
    
    if (property.floor && property.total_floors) {
      html += `<p class="text-sm"><strong>Этаж:</strong> ${property.floor}/${property.total_floors}</p>`
    }
    
    if (property.address) {
      html += `<p class="text-sm text-gray-600">${property.address}</p>`
    }
    
    html += '</div>'
    html += `<a href="${property.url}" class="inline-block mt-3 bg-primary-600 text-white px-4 py-2 rounded text-sm hover:bg-primary-700" style="margin-top: 12px; padding: 8px 16px; background-color: #2563EB; color: white; border-radius: 4px; text-decoration: none; display: inline-block;">Подробнее</a>`
    html += '</div>'
    
    return html
  }

  // ============================================
  // MARKER STYLING
  // ============================================

  getMarkerPreset(property) {
    if (property.is_featured) {
      return 'islands#yellowDotIcon'
    }
    
    if (property.deal_type === 'rent') {
      return 'islands#greenDotIcon'
    }
    
    return 'islands#redDotIcon'
  }

  getMarkerColor(property) {
    if (property.is_featured) {
      return '#FCD34D'
    }
    
    if (property.deal_type === 'rent') {
      return '#10B981'
    }
    
    return '#DC2626'
  }

  // ============================================
  // MAP HELPERS
  // ============================================

  fitBounds(geoObjects) {
    if (geoObjects.length === 0) return

    const bounds = this.map.geoObjects.getBounds()
    
    if (bounds) {
      this.map.setBounds(bounds, {
        checkZoomRange: true,
        zoomMargin: 50
      })
    }
  }

  centerOnProperty(lat, lng) {
    if (this.map) {
      this.map.setCenter([lat, lng], this.zoomValue, {
        duration: 300
      })
    }
  }

  // ============================================
  // ROUTE BUILDING
  // ============================================

  buildRoute(fromCoords, toCoords) {
    if (!this.map) return

    const multiRoute = new ymaps.multiRouter.MultiRoute({
      referencePoints: [fromCoords, toCoords],
      params: {
        routingMode: 'pedestrian'
      }
    }, {
      boundsAutoApply: true,
      wayPointVisible: false
    })

    this.map.geoObjects.add(multiRoute)
  }

  // ============================================
  // DEVICE DETECTION
  // ============================================

  isMobile() {
    return window.innerWidth < 768
  }

  // ============================================
  // ERROR HANDLING
  // ============================================

  showError(message) {
    if (this.hasContainerTarget) {
      this.containerTarget.innerHTML = `
        <div class="flex items-center justify-center h-full bg-gray-100 rounded-lg">
          <div class="text-center p-6">
            <svg class="w-16 h-16 text-gray-400 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
            </svg>
            <p class="text-gray-600">${message}</p>
          </div>
        </div>
      `
    }
  }

  // ============================================
  // ANALYTICS
  // ============================================

  trackEvent(eventName, data = {}) {
    if (typeof ym !== 'undefined' && window.ymId) {
      ym(window.ymId, 'reachGoal', eventName, data)
    }

    if (typeof gtag !== 'undefined') {
      gtag('event', eventName, {
        event_category: 'maps',
        ...data
      })
    }
  }
}