import SearchCombobox, { escapeOption } from '../lib/search_combobox'

export class CreativeTypeEditor {
  constructor(form, onChange) {
    this.root = form.querySelector('[data-creative-type-editor]')
    if (!this.root) return
    this.input = this.root.querySelector('[role="combobox"]')
    this.field = this.root.querySelector('[name="creative[creative_type]"]')
    this.link = this.root.querySelector('a')
    this.error = this.root.querySelector('[role=alert]')
    this.options = JSON.parse(this.root.dataset.options)
    this.popup = new SearchCombobox(this.root.querySelector('.common-popup'), {
      input: this.input, allowCustom: true, addLabel: this.root.dataset.addLabel,
      renderItem: item => escapeOption(item.name),
      onSelect: item => {
        if (item.custom) this.options.push({ value: item.value, name: item.value })
        this.error.textContent = ''
        this.field.value = item.value
        this.field.disabled = false
        this.restoreLabel()
        this.popup.hide()
        onChange()
      }
    })
    this.root.querySelector('button').addEventListener('click', () => {
      this.field.value = this.baseline
      this.restoreLabel()
      this.popup.hide()
      this.error.textContent = ''
      onChange()
    })
    this.input.addEventListener('focus', () => this.show(''))
    this.input.addEventListener('input', () => this.show(this.input.value))
    this.input.addEventListener('keydown', event => this.keydown(event))
    this.input.addEventListener('blur', () => {
      this.popup.hide()
      this.restoreLabel()
    })
  }

  show(query) {
    this.popup.showOptions(this.options, query, {
      canAdd: value => value.length <= 64 && !['inbox', 'workflow_rule'].includes(value)
    })
  }

  keydown(event) {
    if (event.isComposing) return
    if (event.key === 'Escape' || event.key === 'Tab') {
      this.popup.hide()
      this.restoreLabel()
      if (event.key === 'Tab') return
    } else if (!this.popup.handleKey(event)) return
    event.preventDefault()
    event.stopPropagation()
  }

  restoreLabel() {
    this.input.value = this.options.find(item => item.value === this.field.value)?.name || this.field.value
  }

  load(data = {}) {
    if (!this.root) return
    this.popup.hide()
    this.error.textContent = ''
    this.baseline = data.creative_type || ''
    this.field.value = this.baseline
    this.field.disabled = true
    this.input.disabled = ['inbox', 'workflow_rule'].includes(this.field.value)
    if (this.field.value && !this.input.disabled && !this.options.some(item => item.value === this.field.value)) {
      this.options.push({ value: this.field.value, name: this.field.value })
    }
    this.restoreLabel()
    this.updateLink(data)
  }

  updateLink(data) {
    this.link.hidden = data.creative_type !== 'workflow' || !data.id
    this.link.href = `/creatives/${data.id}/edit`
  }

  saved(data, value) {
    if (!this.root) return
    this.updateLink(data)
    this.baseline = data.creative_type ?? this.baseline
    if (this.field.value !== value) return
    this.field.value = data.creative_type ?? value
    this.field.disabled = true
    this.restoreLabel()
  }

  async failed(response) {
    if (this.root) {
      const data = await response.clone().json().catch(() => ({}))
      this.error.textContent = data.error || data.errors?.join(' ') || this.root.dataset.saveFailed
    }
    return response
  }

  async flush(save) {
    let response = await save()
    while (this.value !== undefined && response?.ok !== false) response = await save()
    return response
  }

  async beforeMove(close) {
    return this.value === undefined || await close() !== 'save-failed'
  }

  get value() {
    return this.field && !this.field.disabled ? this.field.value : undefined
  }
}
