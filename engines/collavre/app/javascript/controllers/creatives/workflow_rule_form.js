import DOMPurify from 'dompurify'

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const copy = value => JSON.parse(JSON.stringify(value))
const array = value => Array.isArray(value) ? value : []

export default class WorkflowRuleForm {
  constructor(element, record, vocabulary, labels) {
    this.element = element
    this.record = record
    this.data = vocabulary
    this.labels = labels
    this.draft = copy(record.rule)
    this.render()
  }

  field(name) { return this.element.querySelector(`[name="${name}"]`) }
  role(name) { return this.element.querySelector(`[data-role="${name}"]`) }
  get canManage() { return this.record.id ? this.record.can_manage === true : this.data.can_manage === true }

  messages(role, messages) {
    this.role(role).replaceChildren(...messages.map(message => {
      const p = document.createElement('p')
      p.textContent = message
      return p
    }))
  }

  render() {
    const rule = object(this.draft) ? this.draft : {}
    const conditions = object(rule.when) ? rule.when : {}
    this.role('heading').textContent = this.record.id ? DOMPurify.sanitize(this.record.description, { ALLOWED_TAGS: [], RETURN_DOM_FRAGMENT: true }).textContent : this.labels.add_rule
    this.role('title-label').hidden = Boolean(this.record.id)
    this.field('title').required = !this.record.id
    this.role('saved-title-note').hidden = !this.record.id
    this.role('controls').disabled = !this.canManage
    this.options('event', this.data.event_names, rule.on, this.labels.events)
    this.element.querySelectorAll('[data-field="handler.type"]').forEach(radio => {
      radio.checked = radio.value === rule.handler?.type
    })
    this.renderAgents(rule.handler)
    this.renderSources(rule, conditions)
    this.field('author').value = conditions.author_agent === true ? 'yes' : conditions.author_agent === false ? 'no' : 'any'
    this.field('any-body').checked = !Object.hasOwn(conditions, 'body_contains')
    this.renderTags(conditions.body_contains)
    this.field('any-liquid').checked = !Object.hasOwn(conditions, 'liquid')
    this.field('expression').value = typeof conditions.liquid === 'string' ? conditions.liquid : ''
    this.field('raw').value = JSON.stringify(this.draft, null, 2)
    this.rawPending = false
    this.messages('diagnostics', [...this.record.errors, ...(this.canManage ? [] : [this.labels.read_only])])
    this.warnings()
  }

  options(name, values, selected, labels = {}) {
    const choices = [...new Set([...values, ...array(selected), ...(typeof selected === 'string' ? [selected] : [])])]
      .filter(value => typeof value === 'string' || typeof value === 'number')
    this.field(name).replaceChildren(...choices.map(value => {
      const option = document.createElement('option')
      option.value = value
      option.textContent = typeof labels[value] === 'string' ? labels[value] : value
      option.selected = Array.isArray(selected) ? selected.includes(value) : selected === value
      return option
    }))
    if (selected == null) this.field(name).selectedIndex = -1
  }

  renderAgents(handler) {
    const ids = array(handler?.agent_ids).filter(Number.isInteger)
    const names = Object.fromEntries(this.data.agents.map(agent => [agent.id, agent.name]))
    ids.forEach(id => { if (!names[id]) names[id] = `${this.labels.agent_unavailable} (${id})` })
    this.options('agents', this.data.agents.map(agent => agent.id), ids, names)
    this.field('agents').disabled = handler?.type !== 'agent'
  }

  renderSources(rule, conditions) {
    const selected = array(conditions.source).filter(source => typeof source === 'string')
    const known = typeof rule.on === 'string' ? array(this.data.sources_by_event[rule.on]) : []
    const sources = [...new Set([...known, ...selected])]
    this.field('any-source').checked = !Object.hasOwn(conditions, 'source')
    this.role('sources').replaceChildren(...sources.map(source => {
      const label = document.createElement('label')
      label.className = 'workflow-choice'
      const input = document.createElement('input')
      Object.assign(input, { type: 'checkbox', name: 'source', value: source, checked: selected.includes(source) })
      input.dataset.field = 'when.source'
      const text = this.labels.source_labels[source]
      label.append(input, document.createTextNode(typeof text === 'string' ? text : source))
      return label
    }))
  }

  renderTags(phrases) {
    this.role('tags').replaceChildren(...array(phrases).flatMap((phrase, index) => {
      if (typeof phrase !== 'string') return []
      const button = document.createElement('button')
      button.type = 'button'
      button.textContent = `${phrase} ×`
      button.setAttribute('aria-label', `${this.labels.remove_phrase}: ${phrase}`)
      button.dataset.action = 'creatives--workflow-rule#removePhrase'
      button.dataset.index = index
      return button
    }))
  }

  set(path, value) {
    if (!object(this.draft)) this.draft = {}
    const [key, child] = path.split('.')
    if (!child) this.draft[key] = value
    else {
      if (!object(this.draft[key])) this.draft[key] = {}
      if (value === undefined) delete this.draft[key][child]
      else this.draft[key][child] = value
    }
    if (!this.rawPending) this.field('raw').value = JSON.stringify(this.draft, null, 2)
  }

  change(input) {
    const path = input.dataset.field
    if (!path) return
    const values = {
      'handler.agent_ids': () => [...input.selectedOptions].map(option => Number(option.value)),
      'when.source': () => [...this.element.querySelectorAll('[name="source"]:checked')].map(option => option.value),
      'when.author_agent': () => ({ yes: true, no: false })[input.value]
    }
    const anyPaths = { 'any-source': ['source', []], 'any-body': ['body_contains', []], 'any-liquid': ['liquid', ''] }
    if (anyPaths[path]) {
      const [key, empty] = anyPaths[path]
      this.set(`when.${key}`, input.checked ? undefined : empty)
    } else this.set(path, values[path] ? values[path]() : input.value)
    this.refreshConditions()
    this.field('agents').disabled = this.draft.handler?.type !== 'agent'
    this.warnings()
  }

  refreshConditions() {
    const conditions = object(this.draft.when) ? this.draft.when : {}
    this.renderSources(this.draft, conditions)
    this.field('any-body').checked = !Object.hasOwn(conditions, 'body_contains')
    this.field('any-liquid').checked = !Object.hasOwn(conditions, 'liquid')
    this.renderTags(conditions.body_contains)
    this.field('expression').value = typeof conditions.liquid === 'string' ? conditions.liquid : ''
  }

  addPhrase() {
    const phrase = this.field('phrase').value.trim()
    if (!phrase) return
    const phrases = array(this.draft?.when?.body_contains)
    this.set('when.body_contains', [...new Set([...phrases, phrase])])
    this.field('phrase').value = ''
    this.refreshConditions()
  }

  removePhrase(index) {
    this.set('when.body_contains', array(this.draft?.when?.body_contains).filter((_, position) => position !== index))
    this.refreshConditions()
  }

  warnings() {
    const handler = this.draft?.handler
    const warnings = handler?.type === 'agent' ? array(handler.agent_ids).flatMap(id => {
      const agent = this.data.agents.find(option => option.id === id)
      return agent ? agent.warnings : [this.labels.agent_unavailable]
    }) : []
    this.messages('warnings', [...new Set(warnings)])
  }

  applyRaw() {
    try {
      const value = JSON.parse(this.field('raw').value)
      if (!object(value)) throw new Error()
      this.draft = value
      this.render()
    } catch {
      this.messages('diagnostics', [this.labels.invalid_json])
    }
  }
}
