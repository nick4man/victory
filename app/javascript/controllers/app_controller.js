// app/javascript/controllers/app_controller.js
// Main application Stimulus controller for АН "Виктори"
// Handles global UI interactions and common functionality

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["mobileMenu"]

  connect() {
    console.log("App controller connected")
    this.initializeScrollHandlers()
    this.initializeClickOutside()
  }

  disconnect() {
    this.removeScrollHandlers()
  }

  // ============================================
  // MOBILE MENU
  // ============================================

  toggleMobileMenu(event) {
    event.preventDefault()
    
    if (this.hasMobileMenuTarget) {
      const isHidden = this.mobileMenuTarget.classList.contains('hidden')
      
      if (isHidden) {
        this.openMobileMenu()
      } else {
        this.closeMobileMenu()
      }
    }
  }

  openMobileMenu() {
    if (this.hasMobileMenuTarget) {
      this.mobileMenuTarget.classList.remove('hidden')
      document.body.style.overflow = 'hidden'
      
      // Animate menu
      this.mobileMenuTarget.style.opacity = '0'
      this.mobileMenuTarget.style.transform = 'translateY(-10px)'
      
      requestAnimationFrame(() => {
        this.mobileMenuTarget.style.transition = 'opacity 0.3s, transform 0.3s'
        this.mobileMenuTarget.style.opacity = '1'
        this.mobileMenuTarget.style.transform = 'translateY(0)'
      })
    }
  }

  closeMobileMenu() {
    if (this.hasMobileMenuTarget) {
      this.mobileMenuTarget.style.opacity = '0'
      this.mobileMenuTarget.style.transform = 'translateY(-10px)'
      
      setTimeout(() => {
        this.mobileMenuTarget.classList.add('hidden')
        document.body.style.overflow = ''
      }, 300)
    }
  }

  // Close mobile menu when clicking outside
  handleClickOutside(event) {
    if (this.hasMobileMenuTarget && !this.mobileMenuTarget.classList.contains('hidden')) {
      if (!this.element.contains(event.target)) {
        this.closeMobileMenu()
      }
    }
  }

  initializeClickOutside() {
    this.clickOutsideHandler = this.handleClickOutside.bind(this)
    document.addEventListener('click', this.clickOutsideHandler)
  }

  // ============================================
  // SCROLL HANDLING
  // ============================================

  scrollToTop(event) {
    event.preventDefault()
    
    window.scrollTo({
      top: 0,
      behavior: 'smooth'
    })
  }

  initializeScrollHandlers() {
    this.scrollHandler = this.handleScroll.bind(this)
    window.addEventListener('scroll', this.scrollHandler)
  }

  removeScrollHandlers() {
    if (this.scrollHandler) {
      window.removeEventListener('scroll', this.scrollHandler)
    }
    if (this.clickOutsideHandler) {
      document.removeEventListener('click', this.clickOutsideHandler)
    }
  }

  handleScroll() {
    const backToTopButton = document.getElementById('back-to-top')
    
    if (backToTopButton) {
      if (window.pageYOffset > 300) {
        backToTopButton.classList.remove('hidden')
        backToTopButton.style.opacity = '0'
        requestAnimationFrame(() => {
          backToTopButton.style.transition = 'opacity 0.3s'
          backToTopButton.style.opacity = '1'
        })
      } else {
        backToTopButton.style.opacity = '0'
        setTimeout(() => {
          backToTopButton.classList.add('hidden')
        }, 300)
      }
    }

    // Add shadow to header on scroll
    const header = document.querySelector('header')
    if (header) {
      if (window.pageYOffset > 10) {
        header.classList.add('shadow-md')
      } else {
        header.classList.remove('shadow-md')
      }
    }
  }

  // ============================================
  // FLASH MESSAGES
  // ============================================

  dismissAlert(event) {
    event.preventDefault()
    const alert = event.target.closest('.alert')
    
    if (alert) {
      alert.style.opacity = '1'
      alert.style.transition = 'opacity 0.3s, transform 0.3s'
      alert.style.transform = 'translateY(0)'
      
      requestAnimationFrame(() => {
        alert.style.opacity = '0'
        alert.style.transform = 'translateY(-10px)'
      })
      
      setTimeout(() => {
        alert.remove()
      }, 300)
    }
  }

  // Auto-dismiss flash messages after 5 seconds
  autoDismissFlashes() {
    const alerts = document.querySelectorAll('.alert')
    
    alerts.forEach(alert => {
      setTimeout(() => {
        alert.style.opacity = '0'
        alert.style.transform = 'translateY(-10px)'
        
        setTimeout(() => {
          alert.remove()
        }, 300)
      }, 5000)
    })
  }

  // ============================================
  // MODALS
  // ============================================

  openModal(modalId) {
    const modal = document.getElementById(modalId)
    
    if (modal) {
      modal.classList.remove('hidden')
      document.body.style.overflow = 'hidden'
      
      // Animate modal
      const modalContent = modal.querySelector('div > div')
      if (modalContent) {
        modalContent.style.opacity = '0'
        modalContent.style.transform = 'scale(0.95)'
        
        requestAnimationFrame(() => {
          modalContent.style.transition = 'opacity 0.3s, transform 0.3s'
          modalContent.style.opacity = '1'
          modalContent.style.transform = 'scale(1)'
        })
      }
    }
  }

  closeModal(modalId) {
    const modal = document.getElementById(modalId)
    
    if (modal) {
      const modalContent = modal.querySelector('div > div')
      
      if (modalContent) {
        modalContent.style.opacity = '0'
        modalContent.style.transform = 'scale(0.95)'
      }
      
      setTimeout(() => {
        modal.classList.add('hidden')
        document.body.style.overflow = ''
      }, 300)
    }
  }

  // Close modal on backdrop click
  closeOnBackdrop(event) {
    if (event.target === event.currentTarget) {
      this.closeModal(event.currentTarget.id)
    }
  }

  // Close modal on ESC key
  handleKeydown(event) {
    if (event.key === 'Escape') {
      const openModals = document.querySelectorAll('.fixed:not(.hidden)')
      openModals.forEach(modal => {
        if (modal.id) {
          this.closeModal(modal.id)
        }
      })
    }
  }

  // ============================================
  // FORM HELPERS
  // ============================================

  formatPhone(event) {
    const input = event.target
    let value = input.value.replace(/\D/g, '')
    
    if (value.length > 0) {
      if (value[0] === '8') {
        value = '7' + value.slice(1)
      }
      
      let formatted = '+7'
      
      if (value.length > 1) {
        formatted += ' (' + value.substring(1, 4)
      }
      if (value.length >= 5) {
        formatted += ') ' + value.substring(4, 7)
      }
      if (value.length >= 8) {
        formatted += '-' + value.substring(7, 9)
      }
      if (value.length >= 10) {
        formatted += '-' + value.substring(9, 11)
      }
      
      input.value = formatted
    }
  }

  // ============================================
  // NOTIFICATIONS
  // ============================================

  showNotification(message, type = 'info') {
    const notification = document.createElement('div')
    notification.className = `fixed top-4 right-4 z-50 max-w-sm bg-white rounded-lg shadow-lg border-l-4 ${this.getNotificationColor(type)} p-4 transform transition-all duration-300`
    notification.style.opacity = '0'
    notification.style.transform = 'translateX(100%)'
    
    notification.innerHTML = `
      <div class="flex items-start">
        <div class="flex-shrink-0">
          ${this.getNotificationIcon(type)}
        </div>
        <div class="ml-3 flex-1">
          <p class="text-sm font-medium text-gray-900">${message}</p>
        </div>
        <button type="button" class="ml-4 flex-shrink-0 text-gray-400 hover:text-gray-500" onclick="this.parentElement.parentElement.remove()">
          <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
            <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd"/>
          </svg>
        </button>
      </div>
    `
    
    document.body.appendChild(notification)
    
    // Animate in
    requestAnimationFrame(() => {
      notification.style.opacity = '1'
      notification.style.transform = 'translateX(0)'
    })
    
    // Auto-dismiss after 5 seconds
    setTimeout(() => {
      notification.style.opacity = '0'
      notification.style.transform = 'translateX(100%)'
      
      setTimeout(() => {
        notification.remove()
      }, 300)
    }, 5000)
  }

  getNotificationColor(type) {
    const colors = {
      'success': 'border-green-500',
      'error': 'border-red-500',
      'warning': 'border-yellow-500',
      'info': 'border-blue-500'
    }
    return colors[type] || colors['info']
  }

  getNotificationIcon(type) {
    const icons = {
      'success': '<svg class="w-6 h-6 text-green-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/></svg>',
      'error': '<svg class="w-6 h-6 text-red-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z" clip-rule="evenodd"/></svg>',
      'warning': '<svg class="w-6 h-6 text-yellow-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/></svg>',
      'info': '<svg class="w-6 h-6 text-blue-500" fill="currentColor" viewBox="0 0 20 20"><path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd"/></svg>'
    }
    return icons[type] || icons['info']
  }

  // ============================================
  // LOADING STATES
  // ============================================

  showLoader() {
    const loader = document.getElementById('page-loader')
    if (loader) {
      loader.classList.remove('hidden')
    } else {
      this.createLoader()
    }
  }

  hideLoader() {
    const loader = document.getElementById('page-loader')
    if (loader) {
      loader.classList.add('hidden')
    }
  }

  createLoader() {
    const loader = document.createElement('div')
    loader.id = 'page-loader'
    loader.className = 'fixed inset-0 bg-black bg-opacity-50 z-50 flex items-center justify-center'
    loader.innerHTML = `
      <div class="bg-white rounded-lg p-8 flex flex-col items-center">
        <svg class="animate-spin h-12 w-12 text-primary-600 mb-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
        <p class="text-gray-700 font-medium">Загрузка...</p>
      </div>
    `
    document.body.appendChild(loader)
  }

  // ============================================
  // COPY TO CLIPBOARD
  // ============================================

  copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text)
        .then(() => {
          this.showNotification('Скопировано в буфер обмена', 'success')
        })
        .catch(err => {
          console.error('Failed to copy: ', err)
          this.fallbackCopyToClipboard(text)
        })
    } else {
      this.fallbackCopyToClipboard(text)
    }
  }

  fallbackCopyToClipboard(text) {
    const textArea = document.createElement('textarea')
    textArea.value = text
    textArea.style.position = 'fixed'
    textArea.style.left = '-999999px'
    textArea.style.top = '-999999px'
    document.body.appendChild(textArea)
    textArea.focus()
    textArea.select()
    
    try {
      document.execCommand('copy')
      this.showNotification('Скопировано в буфер обмена', 'success')
    } catch (err) {
      console.error('Fallback: Failed to copy', err)
      this.showNotification('Не удалось скопировать', 'error')
    }
    
    document.body.removeChild(textArea)
  }

  // ============================================
  // FORM VALIDATION
  // ============================================

  validateForm(form) {
    const requiredFields = form.querySelectorAll('[required]')
    let isValid = true
    
    requiredFields.forEach(field => {
      if (!field.value.trim()) {
        field.classList.add('border-red-500')
        isValid = false
      } else {
        field.classList.remove('border-red-500')
      }
    })
    
    return isValid
  }

  // ============================================
  // SMOOTH SCROLL TO ELEMENT
  // ============================================

  scrollToElement(elementId) {
    const element = document.getElementById(elementId)
    
    if (element) {
      const offset = 80 // Header height
      const elementPosition = element.getBoundingClientRect().top
      const offsetPosition = elementPosition + window.pageYOffset - offset
      
      window.scrollTo({
        top: offsetPosition,
        behavior: 'smooth'
      })
    }
  }

  // ============================================
  // DEBOUNCE HELPER
  // ============================================

  debounce(func, wait) {
    let timeout
    return function executedFunction(...args) {
      const later = () => {
        clearTimeout(timeout)
        func(...args)
      }
      clearTimeout(timeout)
      timeout = setTimeout(later, wait)
    }
  }

  // ============================================
  // LOCAL STORAGE HELPERS
  // ============================================

  saveToLocalStorage(key, value) {
    try {
      localStorage.setItem(key, JSON.stringify(value))
    } catch (e) {
      console.error('Failed to save to localStorage:', e)
    }
  }

  getFromLocalStorage(key) {
    try {
      const item = localStorage.getItem(key)
      return item ? JSON.parse(item) : null
    } catch (e) {
      console.error('Failed to get from localStorage:', e)
      return null
    }
  }

  removeFromLocalStorage(key) {
    try {
      localStorage.removeItem(key)
    } catch (e) {
      console.error('Failed to remove from localStorage:', e)
    }
  }

  // ============================================
  // ANALYTICS TRACKING
  // ============================================

  trackEvent(eventName, properties = {}) {
    // Yandex.Metrika
    if (typeof ym !== 'undefined' && window.ymId) {
      ym(window.ymId, 'reachGoal', eventName, properties)
    }
    
    // Google Analytics
    if (typeof gtag !== 'undefined') {
      gtag('event', eventName, properties)
    }
    
    // Console log for development
    if (window.location.hostname === 'localhost') {
      console.log('Event tracked:', eventName, properties)
    }
  }

  // ============================================
  // RESPONSIVE HELPERS
  // ============================================

  isMobile() {
    return window.innerWidth < 768
  }

  isTablet() {
    return window.innerWidth >= 768 && window.innerWidth < 1024
  }

  isDesktop() {
    return window.innerWidth >= 1024
  }

  // ============================================
  // ANIMATION HELPERS
  // ============================================

  fadeIn(element, duration = 300) {
    element.style.opacity = '0'
    element.style.display = 'block'
    
    requestAnimationFrame(() => {
      element.style.transition = `opacity ${duration}ms`
      element.style.opacity = '1'
    })
  }

  fadeOut(element, duration = 300) {
    element.style.opacity = '1'
    element.style.transition = `opacity ${duration}ms`
    element.style.opacity = '0'
    
    setTimeout(() => {
      element.style.display = 'none'
    }, duration)
  }
}