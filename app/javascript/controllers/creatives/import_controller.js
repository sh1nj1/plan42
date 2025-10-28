import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'

export default class extends Controller {
  static targets = ['area', 'dropzone', 'input', 'progress', 'toggle']
  static values = {
    parentId: String,
    uploading: String,
    success: String,
    failed: String,
    onlyMarkdown: String,
  }
  static classes = ['dragover']

  connect() {
    this.hideProgress()
    this.setAreaVisible(this.isAreaVisible())
  }

  toggle(event) {
    event.preventDefault()
    this.hideProgress()
    this.setAreaVisible(!this.isAreaVisible())
  }

  dragOver(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.add(this.dragoverClass)
  }

  dragLeave(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove(this.dragoverClass)
  }

  drop(event) {
    event.preventDefault()
    this.dropzoneTarget.classList.remove(this.dragoverClass)
    const file = event.dataTransfer.files[0]
    if (file) {
      this.handleFile(file)
    }
  }

  pickFile() {
    this.inputTarget.click()
  }

  fileChanged() {
    const file = this.inputTarget.files[0]
    if (file) {
      this.handleFile(file)
      this.inputTarget.value = ''
    }
  }

  async handleFile(file) {
    const lower = file.name.toLowerCase()
    const isMarkdown = lower.endsWith('.md')
    const isPpt = lower.endsWith('.ppt') || lower.endsWith('.pptx')

    if (!isMarkdown && !isPpt) {
      window.alert(this.onlyMarkdownValue)
      return
    }

    this.showProgress(this.uploadingValue)

    const formData = new FormData()
    formData.append('markdown', file)
    if (this.parentIdValue) {
      formData.append('parent_id', this.parentIdValue)
    }

    try {
      const response = await csrfFetch('/creative_imports', {
        method: 'POST',
        headers: { Accept: 'application/json' },
        body: formData,
      })
      const data = await response.json()

      if (data.success) {
        this.showProgress(this.successValue)
        window.setTimeout(() => window.location.reload(), 700)
      } else {
        this.showProgress(data.error || this.failedValue)
        window.setTimeout(() => this.hideProgress(), 3000)
      }
    } catch (error) {
      this.showProgress(this.failedValue)
      window.setTimeout(() => this.hideProgress(), 3000)
    }
  }

  showProgress(message) {
    this.progressTarget.style.display = 'block'
    this.progressTarget.textContent = message
  }

  hideProgress() {
    this.progressTarget.style.display = 'none'
    this.progressTarget.textContent = ''
  }

  isAreaVisible() {
    return this.areaTarget.style.display === 'block'
  }

  setAreaVisible(visible) {
    this.areaTarget.style.display = visible ? 'block' : 'none'
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute('aria-expanded', visible ? 'true' : 'false')
    }
  }
}
