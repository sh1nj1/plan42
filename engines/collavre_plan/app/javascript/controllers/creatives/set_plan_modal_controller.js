import { Controller } from '@hotwired/stimulus'

// Self-contained controller: attaches to the modal wrapper element
// and listens for 'plan:open-modal' on document for cross-element communication.
export default class extends Controller {
  static targets = ['modal', 'form', 'idsInput', 'planSelect']
  static values = {
    selectOne: String,
    selectPlan: String,
  }

  connect() {
    this._openHandler = () => this._open()
    document.addEventListener('plan:open-modal', this._openHandler)
  }

  disconnect() {
    document.removeEventListener('plan:open-modal', this._openHandler)
  }

  // Called via document event from the set-plan button
  _open() {
    if (!this.hasModalTarget) return
    this.modalTarget.style.display = 'flex'
    document.body.classList.add('no-scroll')
  }

  // Can still be called via data-action for elements inside the controller scope
  open(event) {
    event.preventDefault()
    this._open()
  }

  close(event) {
    if (event) event.preventDefault()
    if (!this.hasModalTarget) return
    this.modalTarget.style.display = 'none'
    document.body.classList.remove('no-scroll')
  }

  backdrop(event) {
    if (event.target === this.modalTarget) {
      this.close(event)
    }
  }

  async submit(event) {
    event.preventDefault()
    if (!this.hasFormTarget || !this.hasIdsInputTarget) return
    const ids = this.selectedIds()

    if (ids.length === 0) {
      this.alert(this.selectOneValue)
      return
    }

    const planId = this.planSelectTarget.value
    if (!planId) {
      this.alert(this.selectPlanValue)
      return
    }

    await this.performRequest(this.formTarget.action, 'POST', {
      plan_id: planId,
      creative_ids: ids.join(',')
    })
  }

  async remove(event) {
    event.preventDefault()
    const ids = this.selectedIds()
    if (ids.length === 0) {
      this.alert(this.selectOneValue)
      return
    }

    const planId = this.planSelectTarget.value
    if (!planId) {
      this.alert(this.selectPlanValue)
      return
    }

    await this.performRequest(event.currentTarget.dataset.removePath, 'DELETE', {
      plan_id: planId,
      creative_ids: ids.join(',')
    })
  }

  async performRequest(url, method, body) {
    try {
      const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
      const response = await fetch(url, {
        method: method,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-CSRF-Token': csrfToken
        },
        body: JSON.stringify(body)
      })

      if (response.ok) {
        const data = await response.json()
        this.alert(data.message)
        this.close()
      } else {
        const data = await response.json()
        this.alert(data.error || 'Operation failed')
      }
    } catch (error) {
      console.error(error)
      this.alert('An unexpected error occurred.')
    }
  }

  selectedIds() {
    return Array.from(document.querySelectorAll('.select-creative-checkbox:checked')).map((checkbox) => checkbox.value)
  }

  alert(message) {
    if (!message) return
    window.alert(message)
  }
}
