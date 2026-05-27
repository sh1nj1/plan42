import { Controller } from '@hotwired/stimulus'
import { subscribeToCreatives } from '../../services/creatives_channel'

export default class extends Controller {
  static values = {
    rootId: { type: Number, default: 0 },
    currentUserId: { type: Number, default: 0 },
  }

  connect() {
    this.subscription = null
    this.editingUsers = {} // { creativeId: { userId: { user_name } } }

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

    // Defer ActionCable subscribe until tree finishes loading. Opening the
    // WebSocket while the tree fetch is in flight triggers ERR_NETWORK_CHANGED
    // in Chromium because the browser tears down the in-flight HTTP connection.
    // Exception: Turbo cache restores leave data-loaded="true" so tree_controller
    // skips load() and never dispatches creative-tree:updated — subscribe now.
    const subscribeForRoot = () => {
      if (this.rootIdValue > 0) {
        this.subscribe()
      } else {
        this.inferAndSubscribe()
      }
    }

    if (this.element.dataset.loaded === 'true') {
      subscribeForRoot()
    } else {
      this._handleTreeUpdated = () => {
        this.element.removeEventListener('creative-tree:updated', this._handleTreeUpdated)
        this._handleTreeUpdated = null
        subscribeForRoot()
      }
      this.element.addEventListener('creative-tree:updated', this._handleTreeUpdated)
    }

    document.addEventListener('creative-editing:start', this.handleEditStart)
    document.addEventListener('creative-editing:stop', this.handleEditStop)
  }

  disconnect() {
    document.removeEventListener('creative-editing:start', this.handleEditStart)
    document.removeEventListener('creative-editing:stop', this.handleEditStop)
    if (this._handleTreeUpdated) {
      this.element.removeEventListener('creative-tree:updated', this._handleTreeUpdated)
      this._handleTreeUpdated = null
    }

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
    // Skip re-subscribing here — connect() defers the first subscribe until
    // creative-tree:updated fires so the WebSocket handshake doesn't race
    // the tree's HTTP fetch.
  }

  inferAndSubscribe() {
    // Wait for tree to load, then find root from first row's parent-id
    const tryInfer = () => {
      const firstRow = this.element.querySelector('creative-tree-row[parent-id]')
      if (firstRow) {
        const parentId = parseInt(firstRow.getAttribute('parent-id'), 10)
        if (parentId > 0) {
          this.subscribe(parentId)
          return true
        }
      }
      return false
    }

    if (!tryInfer()) {
      // Tree may not be loaded yet, observe for changes
      const observer = new MutationObserver(() => {
        if (tryInfer()) observer.disconnect()
      })
      observer.observe(this.element, { childList: true, subtree: true })
      // Cleanup after 10s
      setTimeout(() => observer.disconnect(), 10000)
    }
  }

  subscribe(overrideRootId) {
    const rootId = overrideRootId || this.rootIdValue
    if (rootId <= 0) return

    this.subscription = subscribeToCreatives(rootId, {
      onEditing: (data) => this.handleEditing(data),
      onStoppedEditing: (data) => this.handleStoppedEditing(data),
    })
  }

  handleEditing(data) {
    const { creative_id, user_id, user_name, avatar_url } = data
    if (user_id === this.currentUserIdValue) return

    if (!this.editingUsers[creative_id]) {
      this.editingUsers[creative_id] = {}
    }
    this.editingUsers[creative_id][user_id] = { user_name, avatar_url }
    this.updateRowEditingUsers(creative_id)
  }

  handleStoppedEditing(data) {
    const { creative_id, user_id } = data

    if (this.editingUsers[creative_id]) {
      delete this.editingUsers[creative_id][user_id]
      if (Object.keys(this.editingUsers[creative_id]).length === 0) {
        delete this.editingUsers[creative_id]
      }
    }
    this.updateRowEditingUsers(creative_id)
  }

  updateRowEditingUsers(creativeId) {
    const row = document.querySelector(`creative-tree-row[creative-id="${creativeId}"]`)
    if (!row) return // Creative not visible on this page — ignore

    const editors = this.editingUsers[creativeId]
    if (!editors || Object.keys(editors).length === 0) {
      row.editingUsers = []
    } else {
      row.editingUsers = Object.entries(editors).map(([userId, info]) => ({
        user_id: parseInt(userId),
        user_name: info.user_name,
        avatar_url: info.avatar_url,
      }))
    }
  }
}
