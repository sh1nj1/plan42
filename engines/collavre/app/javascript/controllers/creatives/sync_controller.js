import { Controller } from '@hotwired/stimulus'
import { subscribeToCreatives } from '../../services/creatives_channel'

export default class extends Controller {
  static values = {
    rootId: { type: Number, default: 0 },
    currentUserId: { type: Number, default: 0 },
  }

  connect() {
    this.subscription = null
    this.editingUsers = {} // { creativeId: { userId: { user_name, avatar_url } } }

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
    console.log('[CreativeSync] Subscribing to CreativesChannel, root_id:', this.rootIdValue)
    this.subscription = subscribeToCreatives(this.rootIdValue, {
      onConnected: () => console.log('[CreativeSync] CreativesChannel connected'),
      onDisconnected: () => console.log('[CreativeSync] CreativesChannel disconnected'),
      onEditing: (data) => this.handleEditing(data),
      onStoppedEditing: (data) => this.handleStoppedEditing(data),
    })
  }

  handleEditing(data) {
    const { creative_id, user_id, user_name, avatar_url } = data
    if (user_id === this.currentUserIdValue) return

    console.log('[CreativeSync] Editing:', creative_id, 'by', user_name)

    if (!this.editingUsers[creative_id]) {
      this.editingUsers[creative_id] = {}
    }
    this.editingUsers[creative_id][user_id] = { user_name, avatar_url }
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
    if (!row) return

    const editors = this.editingUsers[creativeId]
    if (!editors || Object.keys(editors).length === 0) {
      row.editingUsers = []
    } else {
      row.editingUsers = Object.entries(editors).map(([userId, info]) => ({
        user_id: parseInt(userId),
        user_name: info.user_name,
        avatar_url: info.avatar_url
      }))
    }
  }
}
