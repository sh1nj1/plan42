import { Controller } from '@hotwired/stimulus'
import { initIndicator } from '../../creatives/drag_drop/indicator'
import {
  addGlobalListeners,
  removeGlobalListeners,
  createCreativeTreeDragDrop,
} from '../../creatives/drag_drop/event_handlers'

let connectionCount = 0
let registry = null

export default class extends Controller {
  static values = { partialFailureText: String }

  connect() {
    if (connectionCount === 0) {
      initIndicator()
      addGlobalListeners()
      registry = createCreativeTreeDragDrop({ partialFailureMessage: this.partialFailureTextValue })
    }
    connectionCount += 1
  }

  disconnect() {
    connectionCount = Math.max(0, connectionCount - 1)
    if (connectionCount === 0) {
      registry?.destroy()
      registry = null
      removeGlobalListeners()
    }
  }

}
