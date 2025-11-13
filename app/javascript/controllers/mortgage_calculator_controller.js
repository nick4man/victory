// app/javascript/controllers/mortgage_calculator_controller.js
// Stimulus controller for mortgage calculator
// Calculates monthly payments, total interest, and loan details

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "price",           // Property price input
    "initialPayment",  // Initial payment input
    "rate",            // Interest rate input
    "term",            // Loan term in years input
    "result",          // Monthly payment result
    "totalAmount",     // Total amount to pay
    "totalInterest",   // Total interest
    "loanAmount",      // Actual loan amount
    "initialPercent",  // Initial payment percentage
    "chart"            // Payment schedule chart
  ]

  static values = {
    price: Number,           // Property price
    defaultRate: Number,     // Default interest rate
    defaultTerm: Number,     // Default term in years
    defaultInitialPercent: Number  // Default initial payment %
  }

  connect() {
    console.log("Mortgage calculator controller connected")
    
    // Set default values
    this.setDefaults()
    
    // Initial calculation
    this.calculate()
  }

  // ============================================
  // INITIALIZATION
  // ============================================

  setDefaults() {
    // Set property price if provided
    if (this.hasPriceValue && this.hasPriceTarget) {
      this.priceTarget.value = this.priceValue
    }

    // Set default rate
    if (!this.hasRateTarget || !this.rateTarget.value) {
      const defaultRate = this.hasDefaultRateValue ? this.defaultRateValue : 10.5
      if (this.hasRateTarget) {
        this.rateTarget.value = defaultRate
      }
    }

    // Set default term
    if (!this.hasTermTarget || !this.termTarget.value) {
      const defaultTerm = this.hasDefaultTermValue ? this.defaultTermValue : 20
      if (this.hasTermTarget) {
        this.termTarget.value = defaultTerm
      }
    }

    // Set default initial payment
    if (this.hasPriceTarget && this.hasInitialPaymentTarget && !this.initialPaymentTarget.value) {
      const price = parseFloat(this.priceTarget.value) || 0
      const defaultPercent = this.hasDefaultInitialPercentValue ? this.defaultInitialPercentValue : 20
      this.initialPaymentTarget.value = Math.round(price * (defaultPercent / 100))
    }
  }

  // ============================================
  // MAIN CALCULATION
  // ============================================

  calculate(event) {
    // Get input values
    const propertyPrice = this.getPropertyPrice()
    const initialPayment = this.getInitialPayment()
    const annualRate = this.getAnnualRate()
    const termYears = this.getTerm()

    // Validate inputs
    if (!this.validateInputs(propertyPrice, initialPayment, annualRate, termYears)) {
      this.clearResults()
      return
    }

    // Calculate loan amount
    const loanAmount = propertyPrice - initialPayment

    if (loanAmount <= 0) {
      this.showError('Первоначальный взнос не может быть больше или равен стоимости недвижимости')
      this.clearResults()
      return
    }

    // Calculate monthly payment using annuity formula
    const monthlyRate = annualRate / 12 / 100
    const termMonths = termYears * 12
    
    let monthlyPayment
    if (monthlyRate === 0) {
      // If rate is 0, simple division
      monthlyPayment = loanAmount / termMonths
    } else {
      // Annuity formula: P = S * (i * (1 + i)^n) / ((1 + i)^n - 1)
      const monthlyRatePlusOne = 1 + monthlyRate
      const powResult = Math.pow(monthlyRatePlusOne, termMonths)
      monthlyPayment = loanAmount * (monthlyRate * powResult) / (powResult - 1)
    }

    // Calculate totals
    const totalPayment = monthlyPayment * termMonths
    const totalInterest = totalPayment - loanAmount
    const totalAmount = totalPayment + initialPayment

    // Update UI
    this.displayResults(monthlyPayment, totalPayment, totalInterest, loanAmount, initialPayment, propertyPrice)

    // Track calculation
    this.trackCalculation({
      property_price: propertyPrice,
      loan_amount: loanAmount,
      monthly_payment: monthlyPayment,
      rate: annualRate,
      term: termYears
    })
  }

  // ============================================
  // INPUT GETTERS
  // ============================================

  getPropertyPrice() {
    if (this.hasPriceTarget) {
      return parseFloat(this.priceTarget.value) || 0
    }
    return this.priceValue || 0
  }

  getInitialPayment() {
    return this.hasInitialPaymentTarget ? 
      parseFloat(this.initialPaymentTarget.value) || 0 : 0
  }

  getAnnualRate() {
    return this.hasRateTarget ? 
      parseFloat(this.rateTarget.value) || 0 : 10.5
  }

  getTerm() {
    return this.hasTermTarget ? 
      parseFloat(this.termTarget.value) || 0 : 20
  }

  // ============================================
  // VALIDATION
  // ============================================

  validateInputs(price, initialPayment, rate, term) {
    if (price <= 0) {
      return false
    }

    if (initialPayment < 0) {
      this.showError('Первоначальный взнос не может быть отрицательным')
      return false
    }

    if (initialPayment >= price) {
      this.showError('Первоначальный взнос должен быть меньше стоимости недвижимости')
      return false
    }

    if (rate < 0 || rate > 100) {
      this.showError('Процентная ставка должна быть от 0 до 100%')
      return false
    }

    if (term <= 0 || term > 50) {
      this.showError('Срок кредита должен быть от 1 до 50 лет')
      return false
    }

    // Check minimum initial payment (usually 10-20%)
    const initialPercent = (initialPayment / price) * 100
    if (initialPercent < 10) {
      this.showWarning('Минимальный первоначальный взнос обычно составляет 10-20%')
    }

    return true
  }

  // ============================================
  // DISPLAY RESULTS
  // ============================================

  displayResults(monthlyPayment, totalPayment, totalInterest, loanAmount, initialPayment, propertyPrice) {
    // Monthly payment
    if (this.hasResultTarget) {
      this.resultTarget.textContent = this.formatCurrency(monthlyPayment)
      this.animateNumber(this.resultTarget)
    }

    // Total amount
    if (this.hasTotalAmountTarget) {
      this.totalAmountTarget.textContent = this.formatCurrency(totalPayment + initialPayment)
    }

    // Total interest
    if (this.hasTotalInterestTarget) {
      this.totalInterestTarget.textContent = this.formatCurrency(totalInterest)
    }

    // Loan amount
    if (this.hasLoanAmountTarget) {
      this.loanAmountTarget.textContent = this.formatCurrency(loanAmount)
    }

    // Initial payment percentage
    if (this.hasInitialPercentTarget) {
      const percent = ((initialPayment / propertyPrice) * 100).toFixed(1)
      this.initialPercentTarget.textContent = `${percent}%`
    }

    // Update chart if available
    if (this.hasChartTarget) {
      this.updateChart(loanAmount, totalInterest)
    }
  }

  clearResults() {
    if (this.hasResultTarget) {
      this.resultTarget.textContent = '0 ₽'
    }
    if (this.hasTotalAmountTarget) {
      this.totalAmountTarget.textContent = '0 ₽'
    }
    if (this.hasTotalInterestTarget) {
      this.totalInterestTarget.textContent = '0 ₽'
    }
  }

  // ============================================
  // FORMATTING
  // ============================================

  formatCurrency(value) {
    if (!value || isNaN(value)) return '0 ₽'
    
    const rounded = Math.round(value)
    return `${rounded.toLocaleString('ru-RU')} ₽`
  }

  formatNumber(value) {
    if (!value || isNaN(value)) return '0'
    return Math.round(value).toLocaleString('ru-RU')
  }

  // ============================================
  // ANIMATIONS
  // ============================================

  animateNumber(element) {
    element.style.transform = 'scale(1.1)'
    element.style.transition = 'transform 0.2s ease-in-out'
    
    setTimeout(() => {
      element.style.transform = 'scale(1)'
    }, 200)
  }

  // ============================================
  // INITIAL PAYMENT HELPERS
  // ============================================

  updateInitialPaymentFromPercent(event) {
    const percent = parseFloat(event.target.value) || 0
    const price = this.getPropertyPrice()
    
    if (price > 0 && this.hasInitialPaymentTarget) {
      this.initialPaymentTarget.value = Math.round(price * (percent / 100))
      this.calculate()
    }
  }

  updateInitialPaymentPercent(event) {
    const payment = parseFloat(event.target.value) || 0
    const price = this.getPropertyPrice()
    
    if (price > 0 && this.hasInitialPercentTarget) {
      const percent = ((payment / price) * 100).toFixed(1)
      this.initialPercentTarget.textContent = `${percent}%`
    }
  }

  // ============================================
  // CHART UPDATE
  // ============================================

  updateChart(loanAmount, totalInterest) {
    // Simple visualization of loan vs interest
    const loanPercent = (loanAmount / (loanAmount + totalInterest)) * 100
    const interestPercent = (totalInterest / (loanAmount + totalInterest)) * 100

    if (this.hasChartTarget) {
      this.chartTarget.innerHTML = `
        <div class="flex h-8 rounded-lg overflow-hidden">
          <div class="bg-blue-500" style="width: ${loanPercent}%" title="Сумма кредита: ${this.formatCurrency(loanAmount)}"></div>
          <div class="bg-red-500" style="width: ${interestPercent}%" title="Переплата: ${this.formatCurrency(totalInterest)}"></div>
        </div>
        <div class="flex justify-between mt-2 text-xs text-gray-600">
          <span>Кредит: ${loanPercent.toFixed(1)}%</span>
          <span>Переплата: ${interestPercent.toFixed(1)}%</span>
        </div>
      `
    }
  }

  // ============================================
  // NOTIFICATIONS
  // ============================================

  showError(message) {
    console.error(message)
    // Display error message in UI if error target exists
  }

  showWarning(message) {
    console.warn(message)
    // Display warning message in UI if warning target exists
  }

  // ============================================
  // ANALYTICS
  // ============================================

  trackCalculation(data) {
    // Yandex.Metrika
    if (typeof ym !== 'undefined' && window.ymId) {
      ym(window.ymId, 'reachGoal', 'mortgage_calculated', data)
    }

    // Google Analytics
    if (typeof gtag !== 'undefined') {
      gtag('event', 'mortgage_calculated', {
        event_category: 'mortgage_calculator',
        event_label: 'calculation_completed',
        value: Math.round(data.monthly_payment)
      })
    }
  }
}