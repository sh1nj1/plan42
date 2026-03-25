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
      console.log('[CreativeSync] Edit start event, creativeId:', creativeId, 'subscription:', !!this.subscription)
      if (creativeId && this.subscription) {
        this.subscription.sendEditing(creativeId)
      }
    }
    this.handleEditStop = (e) => {
      const { creativeId } = e.detail
      console.log('[CreativeSync] Edit stop event, creativeId:', creativeId)
      if (creativeId && this.subscription) {
        this.subscription.sendStoppedEditing(creativeId)
      }
    }

    document.addEventListener('creative-editing:start', this.handleEditStart)
    document.addEventListener('creative-editing:stop', this.handleEditStop)

    if (this.rootIdValue > 0) {
      this.subscribe()
    } else {
      // Top-level /creatives page — try to infer root from tree rows
      this.inferAndSubscribe()
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
    if (this.rootIdValue > 0) {
      this.subscribe()
    }
  }

  inferAndSubscribe() {
    // Wait for tree to load, then find root from first row's parent-id
    const tryInfer = () => {
      const firstRow = this.element.querySelector('creative-tree-row[parent-id]')
      if (firstRow) {
        const parentId = parseInt(firstRow.getAttribute('parent-id'), 10)
        if (parentId > 0) {
          console.log('[CreativeSync] Inferred root_id from tree:', parentId)
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

    console.log('[CreativeSync] Subscribing to CreativesChannel, root_id:', rootId)
    this.subscription = subscribeToCreatives(rootId, {
      onConnected: () => console.log('[CreativeSync] CreativesChannel connected'),
      onDisconnected: () => console.log('[CreativeSync] CreativesChannel disconnected'),
      onEditing: (data) => this.handleEditing(data),
      onStoppedEditing: (data) => this.handleStoppedEditing(data),
    })
  }

  handleEditing(data) {
    const { creative_id, user_id, user_name } = data
    if (user_id === this.currentUserIdValue) return

    console.log('[CreativeSync] Editing:', creative_id, 'by', user_name)

    if (!this.editingUsers[creative_id]) {
      this.editingUsers[creative_id] = {}
    }
    this.editingUsers[creative_id][user_id] = { user_name }
    this.updateRowEditingUsers(creative_id)
  }

  handleStoppedEditing(data) {
    const { creative_id, user_id } = data
    console.log('[CreativeSync] Stopped editing:', creative_id, 'by user', user_id)

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
    if (!row) {
      console.log('[CreativeSync] Row not found for editing update:', creativeId)
      return
    }

    const editors = this.editingUsers[creativeId]
    if (!editors || Object.keys(editors).length === 0) {
      row.editingUsers = []
    } else {
      row.editingUsers = Object.entries(editors).map(([userId, info]) => ({
        user_id: parseInt(userId),
        user_name: info.user_name,
      }))
    }
    console.log('[CreativeSync] Updated editingUsers for row', creativeId, ':', row.editingUsers)
  }
}
