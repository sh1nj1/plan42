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

  submit(event) {
    if (!this.hasFormTarget || !this.hasIdsInputTarget) return
    const ids = this.selectedIds()
    this.idsInputTarget.value = ids.join(',')
    if (ids.length === 0) {
      event.preventDefault()
      this.alert(this.selectOneValue)
    }
  }

  remove(event) {
    event.preventDefault()
    const ids = this.selectedIds()
    if (ids.length === 0) {
      this.alert(this.selectOneValue)
      return
    }
    if (!this.hasPlanSelectTarget) {
      this.submit(event)
      return
    }
    const planId = this.planSelectTarget.value
    if (!planId) {
      this.alert(this.selectPlanValue)
      return
    }

    const form = document.createElement('form')
    form.method = 'POST'
    form.action = event.currentTarget.dataset.removePath

    const csrf = document.querySelector('meta[name="csrf-token"]')
    if (csrf) {
      const csrfInput = document.createElement('input')
      csrfInput.type = 'hidden'
      csrfInput.name = 'authenticity_token'
      csrfInput.value = csrf.content
      form.appendChild(csrfInput)
    }

    const methodField = document.createElement('input')
    methodField.type = 'hidden'
    methodField.name = '_method'
    methodField.value = 'delete'
    form.appendChild(methodField)

    const idsField = document.createElement('input')
    idsField.type = 'hidden'
    idsField.name = 'creative_ids'
    idsField.value = ids.join(',')
    form.appendChild(idsField)

    const planField = document.createElement('input')
    planField.type = 'hidden'
    planField.name = 'plan_id'
    planField.value = planId
    form.appendChild(planField)

    document.body.appendChild(form)
    form.submit()
  }

  selectedIds() {
    return Array.from(document.querySelectorAll('.select-creative-checkbox:checked')).map((checkbox) => checkbox.value)
  }

  alert(message) {
    if (!message) return
    window.alert(message)
  }
}
