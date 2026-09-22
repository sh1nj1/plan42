import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../../lib/api/csrf_fetch'
import WorkflowRuleForm from './workflow_rule_form'

export default class extends Controller {
  static targets = ['rules', 'template', 'create', 'status', 'permission']
  static values = { url: String, createUrl: String, ruleUrl: String, labels: Object }

  connect() {
    this.forms = new WeakMap()
    this.load()
  }

  disconnect() { this.request?.abort() }

  async load() {
    this.request?.abort()
    this.request = new AbortController()
    this.statusTarget.textContent = this.labelsValue.loading
    this.createTarget.disabled = true
    try {
      const response = await csrfFetch(this.urlValue, { signal: this.request.signal, headers: { Accept: 'application/json' } })
      if (!response.ok || response.redirected) throw new Error()
      this.vocabulary = await response.json()
      this.rulesTarget.replaceChildren()
      this.vocabulary.rules.forEach(record => this.append(record))
      this.permissionTarget.textContent = this.vocabulary.permission_note
      const canManage = this.vocabulary.can_manage || this.vocabulary.rules.some(record => record.can_manage)
      this.statusTarget.textContent = canManage ? (this.vocabulary.rules.length ? '' : this.labelsValue.empty) : this.labelsValue.read_only
      this.createTarget.disabled = !this.vocabulary.can_manage
    } catch (error) {
      if (error.name !== 'AbortError') this.statusTarget.textContent = this.labelsValue.load_failed
    }
  }

  append(record) {
    const element = this.templateTarget.content.firstElementChild.cloneNode(true)
    const form = new WorkflowRuleForm(element, record, this.vocabulary, this.labelsValue)
    this.forms.set(element, form)
    this.rulesTarget.append(element)
    return form
  }

  add() {
    if (!this.vocabulary?.can_manage) return
    const form = this.append({ description: '', rule: { on: this.vocabulary.event_names[0], handler: { type: 'human' } }, errors: [], warnings: [] })
    this.statusTarget.textContent = ''
    form.field('title').focus()
  }

  form(event) { return this.forms.get(event.target.closest('form')) }
  change(event) { this.form(event).change(event.target) }

  input(event) {
    const form = this.form(event)
    if (event.target.name === 'raw') form.rawPending = true
    if (event.target.name === 'expression') form.change(event.target)
  }

  key(event) {
    if (event.target.name !== 'phrase' || event.key !== 'Enter' || event.isComposing) return
    event.preventDefault()
    this.addPhrase(event)
  }

  addPhrase(event) { this.form(event).addPhrase() }
  removePhrase(event) { this.form(event).removePhrase(Number(event.target.dataset.index)) }
  applyRaw(event) { this.form(event).applyRaw() }

  async save(event) {
    event.preventDefault()
    const form = this.form(event)
    if (!form.canManage || form.saving) return
    if (form.rawPending) return form.messages('diagnostics', [this.labelsValue.raw_pending])
    const payload = { workflow_rule: form.draft }
    if (!form.record.id) payload.description = form.field('title').value
    const url = form.record.id ? this.ruleUrlValue.replace('RULE_ID', form.record.id) : this.createUrlValue
    form.saving = true
    form.role('controls').disabled = true
    try {
      const response = await csrfFetch(url, { method: form.record.id ? 'PATCH' : 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify(payload) })
      if (response.redirected) throw new Error()
      const result = await response.json()
      if (!response.ok) return form.messages('diagnostics', result.errors || [result.error || this.labelsValue.save_failed])
      form.record = result
      form.draft = result.rule
      form.render()
      form.messages('diagnostics', [this.labelsValue.saved, ...result.errors])
    } catch {
      form.messages('diagnostics', [this.labelsValue.save_failed])
    } finally {
      form.saving = false
      form.role('controls').disabled = !form.canManage
    }
  }
}
