import { Controller } from '@hotwired/stimulus'
import { initIndicator } from '../../creatives/drag_drop/indicator'
import {
  addGlobalListeners,
  removeGlobalListeners,
  createCreativeTreeDragDrop,
} from '../../creatives/drag_drop/event_handlers'

import { createCreativeFileDrop } from '../../creatives/drag_drop/file_drop'

let fileRegistry = null
let connectionCount = 0
let registry = null

export default class extends Controller {
  static values = { partialFailureText: String, fileFailureText: String }

  connect() {
    if (connectionCount === 0) {
      fileRegistry = createCreativeFileDrop({ failureMessage: this.fileFailureTextValue })
      initIndicator()
      addGlobalListeners()
      registry = createCreativeTreeDragDrop({ partialFailureMessage: this.partialFailureTextValue })
    }
    connectionCount += 1
  }

  disconnect() {
    connectionCount = Math.max(0, connectionCount - 1)
    if (connectionCount === 0) {
      fileRegistry?.destroy()
      fileRegistry = null
      registry?.destroy()
      registry = null
      removeGlobalListeners()
    }
  }

}
