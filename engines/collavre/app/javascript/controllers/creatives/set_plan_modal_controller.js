import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['modal', 'form', 'idsInput', 'planSelect']
  static values = {
    selectOne: String,
    selectPlan: String,
  }

  open(event) {
    event.preventDefault()
    if (!this.hasModalTarget) return
    this.modalTarget.style.display = 'flex'
    document.body.classList.add('no-scroll')
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
