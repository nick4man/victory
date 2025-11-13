// app/javascript/controllers/favorite_controller.js
// Stimulus controller for managing property favorites
// Handles adding/removing properties to/from favorites

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["icon", "text", "count"]
  static values = {
    propertyId: Number,
    favorited: Boolean,
    url: String
  }

  connect() {
    console.log("Favorite controller connected for property:", this.propertyIdValue)
    this.updateUI()
  }

  // ============================================
  // MAIN ACTIONS
  // ============================================

  toggle(event) {
    event.preventDefault()
    event.stopPropagation() // Prevent link navigation if inside a link

    if (this.favoritedValue) {
      this.remove()
    } else {
      this.add()
    }
  }

  add() {
    this.setLoading(true)

    const url = `/properties/${this.propertyIdValue}/favorite`
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken,
        'Accept': 'application/json'
      },
      credentials: 'same-origin'
    })
      .then(response => {
        if (!response.ok) {
          throw new Error('Network response was not ok')
        }
        return response.json()
      })
      .then(data => {
        if (data.success) {
          this.favoritedValue = true
          this.updateUI()
          this.showNotification('Добавлено в избранное', 'success')
          this.trackEvent('property_favorited')
          this.updateFavoritesCount(1)
        } else {
          throw new Error(data.error || 'Не удалось добавить в избранное')
        }
      })
      .catch(error => {
        console.error('Error adding to favorites:', error)
        this.showNotification(error.message || 'Ошибка при добавлении в избранное', 'error')
      })
      .finally(() => {
        this.setLoading(false)
      })
  }

  remove() {
    this.setLoading(true)

    const url = `/properties/${this.propertyIdValue}/unfavorite`
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    fetch(url, {
      method: 'DELETE',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': csrfToken,
        'Accept': 'application/json'
      },
      credentials: 'same-origin'
    })
      .then(response => {
        if (!response.ok) {
          throw new Error('Network response was not ok')
        }
        return response.json()
      })
      .then(data => {
        if (data.success) {
          this.favoritedValue = false
          this.updateUI()
          this.showNotification('Удалено из избранного', 'info')
          this.trackEvent('property_unfavorited')
          this.updateFavoritesCount(-1)
        } else {
          throw new Error(data.error || 'Не удалось удалить из избранного')
        }
      })
      .catch(error => {
        console.error('Error removing from favorites:', error)
        this.showNotification(error.message || 'Ошибка при удалении из избранного', 'error')
      })
      .finally(() => {
        this.setLoading(false)
      })
  }

  // ============================================
  // UI UPDATE
  // ============================================

  updateUI() {
    if (this.hasIconTarget) {
      this.updateIcon()
    }

    if (this.hasTextTarget) {
      this.updateText()
    }

    if (this.element.tagName === 'BUTTON') {
      this.updateButtonStyle()
    }
  }

  updateIcon() {
    const icon = this.iconTarget

    if (this.favoritedValue) {
      // Filled heart (favorited)
      icon.setAttribute('fill', 'currentColor')
      icon.classList.remove('text-gray-600')
      icon.classList.add('text-red-500')
      
      // Add animation
      this.animateIcon()
    } else {
      // Empty heart (not favorited)
      icon.setAttribute('fill', 'none')
      icon.classList.remove('text-red-500')
      icon.classList.add('text-gray-600')
    }
  }

  updateText() {
    if (this.favoritedValue) {
      this.textTarget.textContent = 'В избранном'
    } else {
      this.textTarget.textContent = 'В избранное'
    }
  }

  updateButtonStyle() {
    const button = this.element

    if (this.favoritedValue) {
      // Favorited state
      button.classList.remove('bg-white', 'border-gray-300', 'text-gray-700')
      button.classList.add('bg-red-500', 'text-white', 'border-red-500')
    } else {
      // Not favorited state
      button.classList.remove('bg-red-500', 'text-white', 'border-red-500')
      button.classList.add('bg-white', 'border-gray-300', 'text-gray-700')
    }
  }

  animateIcon() {
    if (!this.hasIconTarget) return

    // Heart beat animation
    this.iconTarget.style.transform = 'scale(1)'
    this.iconTarget.style.transition = 'transform 0.3s ease-in-out'

    requestAnimationFrame(() => {
      this.iconTarget.style.transform = 'scale(1.3)'
      
      setTimeout(() => {
        this.iconTarget.style.transform = 'scale(1)'
      }, 150)
    })
  }

  // ============================================
  // LOADING STATE
  // ============================================

  setLoading(isLoading) {
    const button = this.element

    if (isLoading) {
      button.disabled = true
      button.style.opacity = '0.6'
      button.style.cursor = 'not-allowed'
    } else {
      button.disabled = false
      button.style.opacity = '1'
      button.style.cursor = 'pointer'
    }
  }

  // ============================================
  // FAVORITES COUNTER
  // ============================================

  updateFavoritesCount(delta) {
    const counterElements = document.querySelectorAll('[data-favorites-count]')

    counterElements.forEach(element => {
      const currentCount = parseInt(element.textContent) || 0
      const newCount = Math.max(0, currentCount + delta)
      
      element.textContent = newCount

      // Hide badge if count is 0
      if (newCount === 0) {
        element.classList.add('hidden')
      } else {
        element.classList.remove('hidden')
      }

      // Animate change
      element.style.transition = 'transform 0.2s'
      element.style.transform = 'scale(1.2)'
      
      setTimeout(() => {
        element.style.transform = 'scale(1)'
      }, 200)
    })
  }

  // ============================================
  // NOTIFICATIONS
  // ============================================

  showNotification(message, type = 'info') {
    // Try to use app controller's notification method
    const appController = this.application.getControllerForElementAndIdentifier(
      document.body.querySelector('[data-controller="app"]'),
      'app'
    )

    if (appController && typeof appController.showNotification === 'function') {
      appController.showNotification(message, type)
    } else {
      // Fallback to simple alert
      console.log(`${type.toUpperCase()}: ${message}`)
      
      // Create simple toast notification
      this.createToast(message, type)
    }
  }

  createToast(message, type = 'info') {
    const colors = {
      'success': 'bg-green-500',
      'error': 'bg-red-500',
      'warning': 'bg-yellow-500',
      'info': 'bg-blue-500'
    }

    const toast = document.createElement('div')
    toast.className = `fixed bottom-4 right-4 ${colors[type] || colors['info']} text-white px-6 py-3 rounded-lg shadow-lg z-50 transition-all duration-300`
    toast.style.opacity = '0'
    toast.style.transform = 'translateY(100%)'
    toast.textContent = message

    document.body.appendChild(toast)

    // Animate in
    requestAnimationFrame(() => {
      toast.style.opacity = '1'
      toast.style.transform = 'translateY(0)'
    })

    // Auto-dismiss after 3 seconds
    setTimeout(() => {
      toast.style.opacity = '0'
      toast.style.transform = 'translateY(100%)'
      
      setTimeout(() => {
        toast.remove()
      }, 300)
    }, 3000)
  }

  // ============================================
  // ANALYTICS
  // ============================================

  trackEvent(eventName) {
    // Yandex.Metrika
    if (typeof ym !== 'undefined' && window.ymId) {
      ym(window.ymId, 'reachGoal', eventName, {
        property_id: this.propertyIdValue
      })
    }

    // Google Analytics
    if (typeof gtag !== 'undefined') {
      gtag('event', eventName, {
        'property_id': this.propertyIdValue,
        'event_category': 'favorites',
        'event_label': `Property ${this.propertyIdValue}`
      })
    }

    // Development logging
    if (window.location.hostname === 'localhost') {
      console.log('Favorite event tracked:', eventName, { property_id: this.propertyIdValue })
    }
  }

  // ============================================
  // ERROR HANDLING
  // ============================================

  handleError(error) {
    console.error('Favorite controller error:', error)
    
    if (error.message.includes('401') || error.message.includes('Unauthorized')) {
      this.showNotification('Необходимо войти в систему', 'warning')
      
      // Redirect to login after a delay
      setTimeout(() => {
        window.location.href = '/users/sign_in'
      }, 1500)
    } else {
      this.showNotification('Произошла ошибка. Попробуйте еще раз.', 'error')
    }
  }
}