// Chat Controller - Stimulus.js
// Real-time chat functionality using ActionCable

import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static targets = [
    "messages",
    "input",
    "sendButton",
    "typingIndicator",
    "onlineStatus",
    "conversationList",
    "chatWindow"
  ]

  static values = {
    userId: Number,
    receiverId: Number,
    conversationId: String
  }

  connect() {
    console.log("Chat controller connected")
    
    this.subscription = null
    this.typingTimeout = null
    this.isTyping = false
    
    this.subscribe()
    this.loadMessages()
    this.setupEventListeners()
  }

  disconnect() {
    console.log("Chat controller disconnected")
    
    if (this.subscription) {
      this.subscription.unsubscribe()
    }
  }

  // Subscribe to ActionCable channel
  subscribe() {
    if (!this.userIdValue) {
      console.error("User ID is required for chat")
      return
    }

    this.subscription = consumer.subscriptions.create(
      { channel: "ChatChannel", user_id: this.userIdValue },
      {
        connected: () => {
          console.log("Connected to chat channel")
          this.updateOnlineStatus(true)
        },

        disconnected: () => {
          console.log("Disconnected from chat channel")
          this.updateOnlineStatus(false)
        },

        received: (data) => {
          console.log("Received data:", data)
          this.handleReceivedData(data)
        }
      }
    )
  }

  // Handle received data from ActionCable
  handleReceivedData(data) {
    switch (data.action) {
      case 'new_message':
        this.appendMessage(data.message, data.sender)
        this.playNotificationSound()
        break
      case 'message_sent':
        this.markMessageAsSent(data.message)
        break
      case 'user_typing':
        this.showTypingIndicator(data.user_name)
        break
      case 'user_stopped_typing':
        this.hideTypingIndicator()
        break
      case 'messages_read':
        this.markMessagesAsRead(data.conversation_id)
        break
      case 'error':
        this.showError(data.message)
        break
    }
  }

  // Send message
  sendMessage(event) {
    event.preventDefault()
    
    const content = this.inputTarget.value.trim()
    if (!content) return
    
    if (!this.receiverIdValue) {
      this.showError("Receiver not specified")
      return
    }

    // Show sending indicator
    this.showSendingIndicator()

    // Send via ActionCable
    this.subscription.send({
      action: 'send_message',
      content: content,
      receiver_id: this.receiverIdValue,
      message_type: 'text'
    })

    // Clear input
    this.inputTarget.value = ''
    this.stopTyping()
  }

  // Load messages for current conversation
  async loadMessages() {
    if (!this.conversationIdValue) return

    try {
      const response = await fetch(`/api/v1/messages?conversation_id=${this.conversationIdValue}`)
      const data = await response.json()

      if (data.messages) {
        data.messages.forEach(message => {
          this.appendMessage(message, message.sender, false)
        })
        this.scrollToBottom()
      }
    } catch (error) {
      console.error("Failed to load messages:", error)
      this.showError("Failed to load messages")
    }
  }

  // Append message to chat
  appendMessage(message, sender, scroll = true) {
    const isOwn = message.sender_id === this.userIdValue
    const messageClass = isOwn ? 'own-message' : 'other-message'

    const messageHtml = `
      <div class="message ${messageClass} mb-4" data-message-id="${message.id}">
        <div class="flex ${isOwn ? 'justify-end' : 'justify-start'}">
          ${!isOwn ? this.renderAvatar(sender) : ''}
          <div class="message-content max-w-xs lg:max-w-md">
            ${!isOwn ? `<div class="text-xs text-gray-600 mb-1">${sender.name}</div>` : ''}
            <div class="rounded-2xl px-4 py-2 ${isOwn ? 'bg-primary-600 text-white' : 'bg-gray-200 text-gray-900'}">
              <p class="text-sm">${this.escapeHtml(message.content)}</p>
            </div>
            <div class="text-xs text-gray-500 mt-1 ${isOwn ? 'text-right' : 'text-left'}">
              ${this.formatTime(message.created_at)}
              ${isOwn && message.read ? '<span class="text-primary-500">✓✓</span>' : ''}
            </div>
          </div>
          ${isOwn ? this.renderAvatar(sender) : ''}
        </div>
      </div>
    `

    if (this.hasMessagesTarget) {
      this.messagesTarget.insertAdjacentHTML('beforeend', messageHtml)
      if (scroll) {
        this.scrollToBottom()
      }
    }
  }

  // Typing indicators
  startTyping() {
    if (this.isTyping) return
    
    this.isTyping = true
    this.subscription.send({
      action: 'typing',
      receiver_id: this.receiverIdValue
    })
  }

  stopTyping() {
    if (!this.isTyping) return
    
    this.isTyping = false
    this.subscription.send({
      action: 'stop_typing',
      receiver_id: this.receiverIdValue
    })
  }

  handleTyping() {
    this.startTyping()
    
    // Clear previous timeout
    clearTimeout(this.typingTimeout)
    
    // Set timeout to stop typing indicator
    this.typingTimeout = setTimeout(() => {
      this.stopTyping()
    }, 3000)
  }

  showTypingIndicator(userName) {
    if (this.hasTypingIndicatorTarget) {
      this.typingIndicatorTarget.textContent = `${userName} печатает...`
      this.typingIndicatorTarget.classList.remove('hidden')
    }
  }

  hideTypingIndicator() {
    if (this.hasTypingIndicatorTarget) {
      this.typingIndicatorTarget.classList.add('hidden')
    }
  }

  // Mark messages as read
  markAsRead() {
    if (!this.conversationIdValue) return

    this.subscription.send({
      action: 'mark_read',
      sender_id: this.receiverIdValue,
      conversation_id: this.conversationIdValue
    })
  }

  markMessagesAsRead(conversationId) {
    if (conversationId === this.conversationIdValue) {
      // Update UI to show messages as read
      const messages = this.messagesTarget.querySelectorAll('.own-message')
      messages.forEach(msg => {
        const timeEl = msg.querySelector('.text-xs')
        if (timeEl && !timeEl.innerHTML.includes('✓✓')) {
          timeEl.innerHTML += ' <span class="text-primary-500">✓✓</span>'
        }
      })
    }
  }

  // Helper methods
  renderAvatar(user) {
    const avatarUrl = user.avatar_url || '/assets/default-avatar.png'
    return `
      <div class="flex-shrink-0 mx-2">
        <img src="${avatarUrl}" alt="${user.name}" class="w-8 h-8 rounded-full">
      </div>
    `
  }

  formatTime(timestamp) {
    const date = new Date(timestamp)
    const now = new Date()
    
    if (date.toDateString() === now.toDateString()) {
      return date.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })
    } else {
      return date.toLocaleString('ru-RU', { 
        day: 'numeric',
        month: 'short',
        hour: '2-digit',
        minute: '2-digit'
      })
    }
  }

  escapeHtml(text) {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }

  scrollToBottom() {
    if (this.hasMessagesTarget) {
      this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
    }
  }

  updateOnlineStatus(online) {
    if (this.hasOnlineStatusTarget) {
      if (online) {
        this.onlineStatusTarget.classList.add('online')
        this.onlineStatusTarget.classList.remove('offline')
      } else {
        this.onlineStatusTarget.classList.add('offline')
        this.onlineStatusTarget.classList.remove('online')
      }
    }
  }

  showSendingIndicator() {
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = true
      this.sendButtonTarget.innerHTML = `
        <svg class="animate-spin h-5 w-5" fill="none" viewBox="0 0 24 24">
          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
        </svg>
      `
    }
  }

  markMessageAsSent(message) {
    if (this.hasSendButtonTarget) {
      this.sendButtonTarget.disabled = false
      this.sendButtonTarget.innerHTML = `
        <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8" />
        </svg>
      `
    }
  }

  showError(message) {
    console.error("Chat error:", message)
    // Show error notification
    if (window.showNotification) {
      window.showNotification('error', message)
    } else {
      alert(message)
    }
  }

  playNotificationSound() {
    // Play notification sound
    try {
      const audio = new Audio('/sounds/notification.mp3')
      audio.volume = 0.5
      audio.play().catch(e => console.log("Could not play sound:", e))
    } catch (e) {
      console.log("Notification sound not available")
    }
  }

  setupEventListeners() {
    // Handle input typing
    if (this.hasInputTarget) {
      this.inputTarget.addEventListener('input', () => {
        this.handleTyping()
      })

      // Handle enter key
      this.inputTarget.addEventListener('keypress', (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
          e.preventDefault()
          this.sendMessage(e)
        }
      })
    }

    // Mark messages as read when chat is visible
    if (this.hasChatWindowTarget) {
      const observer = new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting) {
          this.markAsRead()
        }
      })
      observer.observe(this.chatWindowTarget)
    }
  }
}

