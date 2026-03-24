import { Controller } from '@hotwired/stimulus'
import { subscribeToCreatives } from '../../services/creatives_channel'

const EDITING_INDICATOR_CLASS = 'creative-editing-indicator'

export default class extends Controller {
  static values = {
    rootId: { type: Number, default: 0 },
    currentUserId: { type: Number, default: 0 },
  }

  connect() {
    this.subscription = null
    this.editingUsers = {} // { creativeId: { userId: userName, ... } }
    this.presenceUsers = []

    this.handleEditStart = (e) => {
      const { creativeId } = e.detail
      if (creativeId && this.subscription) {
        this.subscription.sendEditing(creativeId)
      }
    }
    this.handleEditStop = (e) => {
      const { creativeId } = e.detail
      if (creativeId && this.subscription) {
        this.subscription.sendStoppedEditing(creativeId)
      }
    }

    document.addEventListener('creative-editing:start', this.handleEditStart)
    document.addEventListener('creative-editing:stop', this.handleEditStop)

    if (this.rootIdValue > 0) {
      this.subscribe()
    }
  }

  disconnect() {
    document.removeEventListener('creative-editing:start', this.handleEditStart)
    document.removeEventListener('creative-editing:stop', this.handleEditStop)

    if (this.refetchTimer) clearTimeout(this.refetchTimer)
    if (this.subscription) {
      this.subscription.cleanup()
      this.subscription = null
    }
  }

  rootIdValueChanged() {
    if (this.subscription) {
      this.subscription.cleanup()
      this.subscription = null
    }
    if (this.rootIdValue > 0) {
      this.subscribe()
    }
  }

  subscribe() {
    console.log('[CreativeSync] Subscribing to root_id:', this.rootIdValue)
    this.subscription = subscribeToCreatives(this.rootIdValue, {
      onConnected: () => console.log('[CreativeSync] Connected'),
      onDisconnected: () => console.log('[CreativeSync] Disconnected'),
      onCreated: (data) => {
        console.log('[CreativeSync] Created:', data)
        this.handleCreated(data)
      },
      onUpdated: (data) => {
        console.log('[CreativeSync] Updated:', data)
        this.handleUpdated(data)
      },
      onDestroyed: (data) => {
        console.log('[CreativeSync] Destroyed:', data)
        this.handleDestroyed(data)
      },
      onPresence: (data) => {
        console.log('[CreativeSync] Presence:', data)
        this.handlePresence(data)
      },
      onEditing: (data) => this.handleEditing(data),
      onStoppedEditing: (data) => this.handleStoppedEditing(data),
    })
  }

  // --- CRUD handlers ---

  handleCreated(_data) {
    this.debouncedRefetch()
  }

  handleUpdated(_data) {
    this.debouncedRefetch()
  }

  handleDestroyed(_data) {
    this.debouncedRefetch()
  }

  debouncedRefetch() {
    if (this.refetchTimer) clearTimeout(this.refetchTimer)
    this.refetchTimer = setTimeout(() => {
      this.refetchTree()
    }, 300)
  }

  // --- Presence handlers ---

  handlePresence(data) {
    this.presenceUsers = data.user_ids || []
    this.renderPresence()
  }

  renderPresence() {
    const container = document.getElementById('creative-presence-avatars')
    if (!container) return

    // Fetch user info for presence display
    if (this.presenceUsers.length === 0) {
      container.innerHTML = ''
      return
    }

    // Fetch participants info from the comments endpoint (reuse existing)
    const rootId = this.rootIdValue
    fetch(`/creatives/${rootId}/comments/participants`)
      .then((r) => r.json())
      .then((data) => {
        const users = data.users || []
        container.innerHTML = ''

        this.presenceUsers.forEach((userId) => {
          // Skip current user
          if (userId === this.currentUserIdValue) return

          const user = users.find((u) => u.id === userId)
          if (!user) return

          const wrapper = document.createElement('span')
          wrapper.className = 'avatar-wrapper creative-presence-user'
          wrapper.title = user.name

          const img = document.createElement('img')
          img.src = user.avatar_url
          img.alt = user.name
          img.width = 20
          img.height = 20
          img.className = 'avatar'
          img.style.borderRadius = '50%'
          wrapper.appendChild(img)

          if (user.default_avatar) {
            const span = document.createElement('span')
            span.className = 'avatar-initial'
            span.textContent = user.initial
            span.style.fontSize = '10px'
            wrapper.appendChild(span)
          }

          container.appendChild(wrapper)
        })
      })
      .catch(() => {
        // Silently fail - presence is non-critical
      })
  }

  // --- Editing conflict handlers ---

  handleEditing(data) {
    const { creative_id, user_id, user_name } = data
    // Don't show editing indicator for current user
    if (user_id === this.currentUserIdValue) return

    if (!this.editingUsers[creative_id]) {
      this.editingUsers[creative_id] = {}
    }
    this.editingUsers[creative_id][user_id] = user_name
    this.renderEditingIndicator(creative_id)
  }

  handleStoppedEditing(data) {
    const { creative_id, user_id } = data
    if (this.editingUsers[creative_id]) {
      delete this.editingUsers[creative_id][user_id]
      if (Object.keys(this.editingUsers[creative_id]).length === 0) {
        delete this.editingUsers[creative_id]
      }
    }
    this.renderEditingIndicator(creative_id)
  }

  renderEditingIndicator(creativeId) {
    const row = this.findRow(creativeId)
    if (!row) return

    // Remove existing indicator
    const existing = row.querySelector(`.${EDITING_INDICATOR_CLASS}`)
    if (existing) existing.remove()

    const editors = this.editingUsers[creativeId]
    if (!editors || Object.keys(editors).length === 0) {
      row.classList.remove('is-being-edited')
      return
    }

    row.classList.add('is-being-edited')

    const names = Object.values(editors)
    const indicator = document.createElement('span')
    indicator.className = EDITING_INDICATOR_CLASS
    indicator.textContent = `✏️ ${names.join(', ')}`
    indicator.title = names.join(', ')

    // Insert after the description content
    const content = row.shadowRoot?.querySelector('.creative-content') || row.querySelector('.creative-content')
    if (content) {
      content.appendChild(indicator)
    }
  }

  // --- Send editing signals (called from row editor) ---

  notifyEditing(creativeId) {
    if (this.subscription) {
      this.subscription.sendEditing(creativeId)
    }
  }

  notifyStoppedEditing(creativeId) {
    if (this.subscription) {
      this.subscription.sendStoppedEditing(creativeId)
    }
  }

  // --- Helpers ---

  findRow(creativeId) {
    return this.element.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
  }

  refetchTree() {
    // Dispatch event so tree_controller can refetch
    const event = new CustomEvent('creative-sync:refetch', { bubbles: true })
    this.element.dispatchEvent(event)
  }
}
