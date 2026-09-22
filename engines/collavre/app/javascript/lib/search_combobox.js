import CommonPopup, { elementAnchor } from './common_popup'

export function normalizeOption(value) {
  return value.normalize('NFKC').trim().replace(/\s+/gu, ' ').toLowerCase()
}

export function escapeOption(value) {
  const node = document.createElement('span')
  node.textContent = value
  return node.innerHTML
}

// Shared by model and creative type selectors. Consumers decide when a chosen
// value is persisted; typing alone never calls onSelect.
export default class SearchCombobox extends CommonPopup {
  constructor(element, { input, allowCustom = false, addLabel = '', ...options }) {
    super(element, options)
    this.input = input
    this.allowCustom = allowCustom
    this.addLabel = addLabel
    this.listElement.id ||= `${input.id}-options`
    this.listElement.setAttribute('role', 'listbox')
    input.setAttribute('role', 'combobox')
    input.setAttribute('aria-autocomplete', 'list')
    input.setAttribute('aria-controls', this.listElement.id)
    input.setAttribute('aria-expanded', 'false')
    this.onActiveChange = () => this.syncActive()
  }

  showOptions(options, term, { label = item => item.name, canAdd = () => true } = {}) {
    const query = normalizeOption(term)
    const filtered = options.filter(item => normalizeOption(label(item)).includes(query))
    if (this.allowCustom && query && canAdd(query) &&
        !options.some(item => normalizeOption(label(item)) === query || item.value === query)) {
      filtered.push({ name: this.addLabel.replace('%{name}', query), value: query, custom: true })
    }
    if (!filtered.length) return this.hide()
    this.setItems(filtered)
    Array.from(this.listElement.children).forEach((row, index) => {
      row.id = `${this.listElement.id}-${index}`
      row.setAttribute('role', 'option')
    })
    this.showAt(elementAnchor(this.input))
    this.input.setAttribute('aria-expanded', 'true')
    this.syncActive()
  }

  syncActive() {
    Array.from(this.listElement.children).forEach((row, index) => {
      row.setAttribute('aria-selected', String(index === this.activeIndex))
    })
    const row = this.listElement.children[this.activeIndex]
    if (row) this.input.setAttribute('aria-activedescendant', row.id)
  }

  hide(reason) {
    super.hide(reason)
    this.input.setAttribute('aria-expanded', 'false')
    this.input.removeAttribute('aria-activedescendant')
  }
}
