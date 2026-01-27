import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'

export default class extends Controller {
  static targets = [
    'toggle',
    'checkbox',
    'row',
    'selectAll',
    'deleteButton',
    'setPlan',
  ]

  connect() {
    this.active = false
    this.dragging = false
    this.dragMode = 'toggle'
    this.rowListeners = new Map()

    this.handleDocumentMouseUp = this.handleDocumentMouseUp.bind(this)
    document.addEventListener('mouseup', this.handleDocumentMouseUp)

    this.handleTurboLoad = this.attachRowHandlers.bind(this)
    document.addEventListener('turbo:load', this.handleTurboLoad)

    this.attachRowHandlers()
  }

  disconnect() {
    document.removeEventListener('mouseup', this.handleDocumentMouseUp)
    document.removeEventListener('turbo:load', this.handleTurboLoad)

    this.rowListeners.forEach((handlers, row) => {
      row.removeEventListener('mousedown', handlers.mousedown)
      row.removeEventListener('mouseenter', handlers.mouseenter)
    })
    this.rowListeners = new Map()
  }

  toggle(event) {
    event.preventDefault()
    this.active = !this.active

    this.updateUiForMode()

    if (this.active) {
      this.attachRowHandlers()
    } else {
      this.clearSelection()
      if (this.hasSelectAllTarget) {
        this.selectAllTarget.checked = false
      }
    }

    if (this.hasToggleTarget) {
      const selectText = this.toggleTarget.dataset.selectText
      const cancelText = this.toggleTarget.dataset.cancelText
      this.toggleTarget.textContent = this.active ? cancelText : selectText
      this.toggleTarget.setAttribute('aria-pressed', this.active ? 'true' : 'false')
    }
  }

  checkboxChanged(event) {
    const checkbox = event.currentTarget
    const row = this.findRowForElement(checkbox)
    if (!row) return
    row.classList.toggle('selected', checkbox.checked)
  }

  toggleSelectAll(event) {
    const checked = event.currentTarget.checked
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = checked
      const row = this.findRowForElement(checkbox)
      if (row) {
        row.classList.toggle('selected', checked)
      }
    })
  }

  async deleteSelected(event) {
    event.preventDefault()
    const ids = Array.from(this.element.querySelectorAll('.select-creative-checkbox:checked')).map((cb) => cb.value)
    if (ids.length === 0) return

    const confirmMessage = this.hasDeleteButtonTarget ? this.deleteButtonTarget.dataset.confirm : undefined
    if (confirmMessage && !window.confirm(confirmMessage)) {
      return
    }

    await Promise.all(
      ids.map((id) =>
        csrfFetch(`/creatives/${id}?delete_with_children=false`, {
          method: 'DELETE',
          headers: { Accept: 'application/json' },
        })
      )
    )

    ids.forEach((id) => {
      const tree = document.getElementById(`creative-${id}`)
      if (tree) tree.remove()
    })

    this.clearSelection()
    if (this.hasSelectAllTarget) {
      this.selectAllTarget.checked = false
    }
  }

  rowTargetConnected(row) {
    this.registerRowListeners(row)
  }

  rowTargetDisconnected(row) {
    const handlers = this.rowListeners.get(row)
    if (handlers) {
      row.removeEventListener('mousedown', handlers.mousedown)
      row.removeEventListener('mouseenter', handlers.mouseenter)
      this.rowListeners.delete(row)
    }
  }

  handleDocumentMouseUp() {
    this.dragging = false
  }

  attachRowHandlers() {
    this.rowTargets.forEach((row) => this.registerRowListeners(row))
  }

  registerRowListeners(row) {
    if (this.rowListeners.has(row)) return

    const handlers = {
      mousedown: (event) => this.handleRowMouseDown(event, row),
      mouseenter: () => this.handleRowMouseEnter(row),
    }

    row.addEventListener('mousedown', handlers.mousedown)
    row.addEventListener('mouseenter', handlers.mouseenter)

    this.rowListeners.set(row, handlers)
  }

  handleRowMouseDown(event, row) {
    if (!this.active) return
    if (event.target.closest('.select-creative-checkbox')) return

    const tree = row.closest('.creative-tree')
    const isDraggable = tree && tree.getAttribute('draggable') !== 'false'
    const alreadySelected = row.classList.contains('selected')

    this.dragMode = event.altKey ? 'remove' : event.shiftKey ? 'add' : 'toggle'

    const shouldToggle = !isDraggable || !alreadySelected || event.altKey || event.shiftKey

    this.dragging = shouldToggle

    if (shouldToggle) {
      this.applySelection(row, this.dragMode)
      event.preventDefault()
    }
  }

  handleRowMouseEnter(row) {
    if (this.dragging && this.active) {
      this.applySelection(row, this.dragMode)
    }
  }

  applySelection(row, mode) {
    const checkbox = row.querySelector('.select-creative-checkbox')
    if (!checkbox) return

    if (mode === 'remove') {
      checkbox.checked = false
      row.classList.remove('selected')
    } else if (mode === 'add') {
      checkbox.checked = true
      row.classList.add('selected')
    } else {
      checkbox.checked = !checkbox.checked
      row.classList.toggle('selected', checkbox.checked)
    }
  }

  clearSelection() {
    this.checkboxTargets.forEach((checkbox) => {
      checkbox.checked = false
      const row = this.findRowForElement(checkbox)
      if (row) {
        row.classList.remove('selected')
      }
    })
  }

  updateUiForMode() {
    const show = this.active

    this.checkboxTargets.forEach((checkbox) => {
      checkbox.style.display = show ? '' : 'none'
    })

    this.toggleElements('.add-creative-btn', !show)
    this.toggleElements('.creative-tags', !show)
    this.toggleElements('.comments-btn', !show)

    if (this.hasSelectAllTarget) {
      this.selectAllTarget.style.display = show ? '' : 'none'
    }

    if (this.hasSetPlanTarget) {
      this.setPlanTarget.style.display = show ? '' : 'none'
    }

    if (this.hasDeleteButtonTarget) {
      this.deleteButtonTarget.style.display = show ? '' : 'none'
    }
  }

  toggleElements(selector, shouldShow) {
    this.element.querySelectorAll(selector).forEach((element) => {
      element.style.display = shouldShow ? '' : 'none'
    })
  }

  findRowForElement(element) {
    return element.closest('.creative-row')
  }
}
