import { Controller } from '@hotwired/stimulus'
import { initIndicator } from '../../creatives/drag_drop/indicator'
import {
  addGlobalListeners,
  removeGlobalListeners,
  handleDragStart,
  handleDragOver,
  handleDrop,
  handleDragLeave,
} from '../../creatives/drag_drop/event_handlers'

let connectionCount = 0

export default class extends Controller {
  connect() {
    if (connectionCount === 0) {
      initIndicator()
      addGlobalListeners()
    }
    connectionCount += 1
  }

  disconnect() {
    connectionCount = Math.max(0, connectionCount - 1)
    if (connectionCount === 0) {
      removeGlobalListeners()
    }
  }

  start(event) {
    handleDragStart(event)
  }

  over(event) {
    handleDragOver(event)
  }

  drop(event) {
    handleDrop(event)
  }

  leave(event) {
    handleDragLeave(event)
  }
}
