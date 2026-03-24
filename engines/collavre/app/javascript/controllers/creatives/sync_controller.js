import { Controller } from '@hotwired/stimulus'
import { subscribeToCreatives } from '../../services/creatives_channel'

const EDITING_INDICATOR_CLASS = 'creative-editing-indicator'

export default class extends Controller {
  static values = {
    rootId: Number,
    currentUserId: Number,
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

    if (this.rootIdValue) {
      this.subscribe()
    }
  }

  disconnect() {
    document.removeEventListener('creative-editing:start', this.handleEditStart)
    document.removeEventListener('creative-editing:stop', this.handleEditStop)

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
    if (this.rootIdValue) {
      this.subscribe()
    }
  }

  subscribe() {
    this.subscription = subscribeToCreatives(this.rootIdValue, {
      onCreated: (data) => this.handleCreated(data),
      onUpdated: (data) => this.handleUpdated(data),
      onDestroyed: (data) => this.handleDestroyed(data),
      onPresence: (data) => this.handlePresence(data),
      onEditing: (data) => this.handleEditing(data),
      onStoppedEditing: (data) => this.handleStoppedEditing(data),
    })
  }

  // --- CRUD handlers ---

  handleCreated(data) {
    const { creative } = data
    if (!creative) return

    // Refetch the tree to get properly rendered node with all templates
    this.refetchTree()
  }

  handleUpdated(data) {
    const { creative, ancestors } = data
    if (!creative) return

    // Update the creative row in the DOM
    const row = this.findRow(creative.id)
    if (row) {
      // Update description
      if (creative.description != null) {
        const descTemplate = row.querySelector('template[data-part="description"]')
        if (descTemplate) {
          descTemplate.innerHTML = creative.description
        }
        row.descriptionHtml = creative.description
        row.dataset.descriptionHtml = creative.description
        row.dataset.descriptionRawHtml = creative.description_raw_html || ''
      }

      // Update progress
      if (creative.progress != null) {
        row.dataset.progressValue = creative.progress
      }

      // Trigger re-render
      if (typeof row.requestUpdate === 'function') {
        row.requestUpdate()
      }
    }

    // Update ancestor progress bars
    if (Array.isArray(ancestors)) {
      ancestors.forEach((anc) => {
        const ancRow = this.findRow(anc.id)
        if (ancRow && anc.progress != null) {
          ancRow.dataset.progressValue = anc.progress
          if (typeof ancRow.requestUpdate === 'function') {
            ancRow.requestUpdate()
          }
        }
      })
    }

    // Also update the title row if it matches
    const titleRow = document.querySelector('creative-tree-row[is-title]')
    if (titleRow) {
      const titleId = parseInt(titleRow.getAttribute('creative-id'), 10)
      if (titleId === creative.id && creative.progress != null) {
        titleRow.dataset.progressValue = creative.progress
        if (typeof titleRow.requestUpdate === 'function') {
          titleRow.requestUpdate()
        }
      }
      // Check ancestors for title update
      if (Array.isArray(ancestors)) {
        const titleAncestor = ancestors.find((a) => a.id === titleId)
        if (titleAncestor) {
          titleRow.dataset.progressValue = titleAncestor.progress
          if (typeof titleRow.requestUpdate === 'function') {
            titleRow.requestUpdate()
          }
        }
      }
    }
  }

  handleDestroyed(data) {
    const { creative } = data
    if (!creative) return

    const row = this.findRow(creative.id)
    if (row) {
      // Also remove the children container if exists
      const domId = row.getAttribute('dom-id')
      if (domId) {
        const childrenContainer = document.getElementById(`children-of-${domId}`)
        if (childrenContainer) childrenContainer.remove()
      }
      row.remove()
    }
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
