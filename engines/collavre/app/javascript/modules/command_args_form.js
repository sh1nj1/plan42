/**
 * Command Args Form — renders a modal dialog for slash command parameters.
 *
 * Uses the shared .modal-dialog pattern (overlay + centered panel).
 * When a command with `input_schema` is selected from the command menu,
 * this module shows a form with labeled inputs, validates required fields,
 * and builds the final command string to insert into the textarea.
 */

const OVERLAY_ID = 'command-args-overlay'
const DIALOG_ID = 'command-args-dialog'
const MENTION_DEBOUNCE_MS = 200

export default class CommandArgsForm {
  /**
   * @param {Object} opts
   * @param {Function} opts.onSubmit  - called with the final command string
   * @param {Function} opts.onCancel  - called when the form is dismissed
   * @param {Object}   opts.labels    - { submit, cancel } button text
   * @param {Element}  opts.container - if set, the modal is scoped inside this element
   *                                    (overlay covers only the container, content is blurred)
   * @param {Function} opts.creativeIdFn - returns current creative ID for mention search
   */
  constructor({ onSubmit, onCancel, labels, container, creativeIdFn } = {}) {
    this.onSubmit = onSubmit || (() => {})
    this.onCancel = onCancel || (() => {})
    this.labels = labels || { submit: 'OK', cancel: 'Cancel' }
    this.container = container || null
    this._creativeIdFn = creativeIdFn || (() => null)
    this.command = null
    this.overlay = null
    this.dialog = null
    this._mentionPopup = null
    this._mentionTimer = null
    this._activeMentionInput = null
    this._handleKeydown = this._handleKeydown.bind(this)
  }

  /**
   * Show the args form for the given command.
   * @param {Object} command - Command object with label, input_schema, name, etc.
   */
  show(command) {
    this.hide()
    if (!command?.input_schema?.length) return

    this.command = command
    this._buildModal(command)

    // Focus the first input
    const firstInput = this.dialog.querySelector('input, select, textarea')
    if (firstInput) firstInput.focus()

    document.addEventListener('keydown', this._handleKeydown)
  }

  hide() {
    clearTimeout(this._mentionTimer)
    if (this.overlay) {
      this.overlay.remove()
      this.overlay = null
    }
    if (this.dialog) {
      this.dialog.remove()
      this.dialog = null
    }
    // Restore container state
    if (this.container) {
      this.container.classList.remove('modal-dialog-container')
    }
    this.command = null
    document.removeEventListener('keydown', this._handleKeydown)
  }

  isOpen() {
    return !!this.dialog
  }

  // --- Private ---

  _buildModal(command) {
    const scoped = !!this.container
    const host = scoped ? this.container : document.body

    // When scoped, mark the container so CSS can apply position:relative
    if (scoped) {
      this.container.classList.add('modal-dialog-container')
    }

    // Overlay
    this.overlay = document.createElement('div')
    this.overlay.id = OVERLAY_ID
    this.overlay.className = scoped
      ? 'modal-dialog-overlay modal-dialog-overlay--scoped open'
      : 'modal-dialog-overlay open'
    this.overlay.addEventListener('click', () => {
      this.hide()
      this.onCancel()
    })
    host.appendChild(this.overlay)

    // Dialog panel
    this.dialog = document.createElement('div')
    this.dialog.id = DIALOG_ID
    this.dialog.className = scoped
      ? 'modal-dialog modal-dialog-compact modal-dialog--scoped open'
      : 'modal-dialog modal-dialog-compact open'

    // Prevent overlay click when clicking inside dialog
    this.dialog.addEventListener('mousedown', (e) => e.stopPropagation())
    this.dialog.addEventListener('touchstart', (e) => e.stopPropagation())

    // Header
    const header = document.createElement('div')
    header.className = 'modal-dialog-header'
    header.innerHTML = `<span class="modal-dialog-title">${command.label}</span>`
    if (command.description) {
      header.innerHTML += `<span class="modal-dialog-desc">${command.description}</span>`
    }
    this.dialog.appendChild(header)

    // Body — fields
    const body = document.createElement('div')
    body.className = 'modal-dialog-body'

    const fields = document.createElement('div')
    fields.className = 'modal-dialog-fields'

    command.input_schema.forEach((param, index) => {
      const field = this._buildField(param, index)
      fields.appendChild(field)
    })
    body.appendChild(fields)
    this.dialog.appendChild(body)

    // Footer — actions + hints
    const footer = document.createElement('div')
    footer.className = 'modal-dialog-footer'

    const hints = document.createElement('div')
    hints.className = 'modal-dialog-hints'
    hints.style.marginRight = 'auto'
    hints.innerHTML =
      `<span class="modal-dialog-hint"><kbd>↵</kbd> OK</span>` +
      `<span class="modal-dialog-hint"><kbd>ESC</kbd> Cancel</span>`
    footer.appendChild(hints)

    const cancelBtn = document.createElement('button')
    cancelBtn.type = 'button'
    cancelBtn.className = 'modal-dialog-btn modal-dialog-btn-secondary'
    cancelBtn.textContent = this.labels.cancel
    cancelBtn.addEventListener('click', () => {
      this.hide()
      this.onCancel()
    })

    const submitBtn = document.createElement('button')
    submitBtn.type = 'button'
    submitBtn.className = 'modal-dialog-btn modal-dialog-btn-primary'
    submitBtn.textContent = this.labels.submit
    submitBtn.addEventListener('click', () => this._submit())

    footer.appendChild(cancelBtn)
    footer.appendChild(submitBtn)
    this.dialog.appendChild(footer)

    host.appendChild(this.dialog)
  }

  _buildField(param, index) {
    const wrapper = document.createElement('div')
    wrapper.className = 'modal-dialog-field'

    const label = document.createElement('label')
    label.className = 'modal-dialog-label'
    label.textContent = param.name
    if (param.required) {
      const req = document.createElement('span')
      req.className = 'modal-dialog-required'
      req.textContent = '*'
      label.appendChild(req)
    }
    wrapper.appendChild(label)

    let input
    if (param.format === 'mention') {
      input = this._buildMentionField(param, wrapper)
      wrapper.appendChild(input)
      return wrapper
    }
    if (param.enum && param.enum.length > 0) {
      input = document.createElement('select')
      input.className = 'modal-dialog-input'
      if (!param.required) {
        const opt = document.createElement('option')
        opt.value = ''
        opt.textContent = '\u2014'
        input.appendChild(opt)
      }
      param.enum.forEach((val) => {
        const opt = document.createElement('option')
        opt.value = val
        opt.textContent = val
        input.appendChild(opt)
      })
    } else if (param.type === 'boolean') {
      input = document.createElement('select')
      input.className = 'modal-dialog-input'
      const optEmpty = document.createElement('option')
      optEmpty.value = ''
      optEmpty.textContent = '\u2014'
      const optTrue = document.createElement('option')
      optTrue.value = 'true'
      optTrue.textContent = 'true'
      const optFalse = document.createElement('option')
      optFalse.value = 'false'
      optFalse.textContent = 'false'
      input.appendChild(optEmpty)
      input.appendChild(optTrue)
      input.appendChild(optFalse)
    } else if (param.type === 'integer' || param.type === 'float') {
      input = document.createElement('input')
      input.type = 'number'
      input.className = 'modal-dialog-input'
      if (param.type === 'float') input.step = 'any'
    } else {
      input = document.createElement('textarea')
      input.className = 'modal-dialog-input'
      input.rows = 1
      input.addEventListener('input', () => this._autoResize(input))
    }

    input.dataset.paramName = param.name
    input.dataset.paramType = param.type || 'string'
    input.dataset.paramRequired = param.required ? 'true' : 'false'
    if (param.description) input.placeholder = param.description

    // Enter submits; Shift+Enter inserts newline (textarea only)
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault()
        this._submit()
      }
    })

    wrapper.appendChild(input)
    return wrapper
  }

  _submit() {
    const values = this._collectValues()
    if (!values) return // validation failed

    const commandText = this._buildCommandText(this.command, values)
    this.hide()
    this.onSubmit(commandText)
  }

  _collectValues() {
    if (!this.dialog) return null

    const inputs = this.dialog.querySelectorAll('[data-param-name]')
    const values = {}
    let valid = true

    inputs.forEach((input) => {
      const name = input.dataset.paramName
      const required = input.dataset.paramRequired === 'true'
      const val = input.value.trim()

      input.classList.remove('modal-dialog-error')

      if (required && !val) {
        input.classList.add('modal-dialog-error')
        valid = false
        return
      }

      if (val) {
        values[name] = this._castValue(val, input.dataset.paramType)
      }
    })

    if (!valid) {
      // Focus first error field
      const errorField = this.dialog.querySelector('.modal-dialog-error')
      if (errorField) errorField.focus()
      return null
    }

    return values
  }

  _castValue(val, type) {
    switch (type) {
      case 'integer': return parseInt(val, 10)
      case 'float': return parseFloat(val)
      case 'boolean': return val === 'true'
      default: return val
    }
  }

  /**
   * Build the final command text.
   * Built-in commands use their natural text format.
   * MCP commands use key=value pairs (or JSON for complex values).
   */
  _buildCommandText(command, values) {
    const keys = Object.keys(values)
    if (keys.length === 0) return command.label

    // For built-in commands with special formatting
    if (command.name === 'calendar') {
      return this._buildCalendarText(command, values)
    }
    if (command.name === 'topic') {
      return this._buildTopicText(command, values)
    }
    if (command.name === 'work') {
      return this._buildWorkText(command, values)
    }
    if (command.name === 'compress') {
      return this._buildCompressText(command, values)
    }

    // MCP commands: use key=value for simple types, JSON if any complex values
    const hasComplex = keys.some((k) => typeof values[k] === 'object')
    if (hasComplex) {
      return `${command.label} ${JSON.stringify(values)}`
    }

    const pairs = keys.map((k) => `${k}=${values[k]}`).join(' ')
    return `${command.label} ${pairs}`
  }

  _buildCalendarText(command, values) {
    const parts = [command.label]
    if (values.date) parts.push(values.date)
    if (values.memo) parts.push(values.memo)
    return parts.join(' ')
  }

  _buildTopicText(command, values) {
    const parts = [command.label]
    if (values.topic_name) parts.push(`"${values.topic_name}"`)
    if (values.agent_name) {
      parts.push(values.agent_name)
    }
    return parts.join(' ')
  }

  _buildWorkText(command, values) {
    const parts = [command.label]
    if (values.agent_name) {
      parts.push(values.agent_name)
    }
    if (values.context) parts.push(values.context)
    return parts.join(' ')
  }

  _buildCompressText(command, values) {
    const parts = [command.label]
    if (values.instructions) parts.push(values.instructions)
    return parts.join(' ')
  }

  _buildMentionField(param, wrapper) {
    const fieldContainer = document.createElement('div')
    fieldContainer.className = 'modal-dialog-mention-field'
    fieldContainer.style.position = 'relative'

    const input = document.createElement('input')
    input.type = 'text'
    input.className = 'modal-dialog-input'
    input.dataset.paramName = param.name
    input.dataset.paramType = 'string'
    input.dataset.paramFormat = 'mention'
    input.dataset.paramRequired = param.required ? 'true' : 'false'
    if (param.description) input.placeholder = param.description
    input.autocomplete = 'off'

    // Mention dropdown list
    const dropdown = document.createElement('ul')
    dropdown.className = 'modal-dialog-mention-dropdown'
    dropdown.style.display = 'none'

    // Search on input — strip leading "@" so API gets a clean query
    input.addEventListener('input', () => {
      const raw = input.value.trim()
      const q = raw.replace(/^@/, '')
      if (q.length === 0) {
        dropdown.style.display = 'none'
        return
      }
      clearTimeout(this._mentionTimer)
      this._mentionTimer = setTimeout(() => {
        this._fetchMentions(q).then((users) => {
          this._renderMentionDropdown(dropdown, input, users)
        })
      }, MENTION_DEBOUNCE_MS)
    })

    // Enter submits form (not mention selection)
    input.addEventListener('keydown', (e) => {
      if (dropdown.style.display === 'block') {
        if (e.key === 'ArrowDown') {
          e.preventDefault()
          this._moveMentionActive(dropdown, 1)
          return
        }
        if (e.key === 'ArrowUp') {
          e.preventDefault()
          this._moveMentionActive(dropdown, -1)
          return
        }
        if (e.key === 'Enter' || e.key === 'Tab') {
          const active = dropdown.querySelector('.active')
          if (active) {
            e.preventDefault()
            active.click()
            return
          }
        }
        if (e.key === 'Escape') {
          e.preventDefault()
          dropdown.style.display = 'none'
          return
        }
      }
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault()
        this._submit()
      }
    })

    // Hide dropdown on blur (delayed so click can register)
    input.addEventListener('blur', () => {
      setTimeout(() => { dropdown.style.display = 'none' }, 200)
    })

    fieldContainer.appendChild(input)
    fieldContainer.appendChild(dropdown)
    return fieldContainer
  }

  _fetchMentions(query) {
    const url = new URL('/users/search', window.location.origin)
    url.searchParams.set('q', query)
    const creativeId = this._creativeIdFn()
    if (creativeId) {
      url.searchParams.set('creative_id', creativeId)
    }
    return fetch(url, { headers: { Accept: 'application/json' } })
      .then((r) => r.ok ? r.json() : [])
      .catch(() => [])
  }

  _renderMentionDropdown(dropdown, input, users) {
    dropdown.innerHTML = ''
    if (!users || users.length === 0) {
      dropdown.style.display = 'none'
      return
    }

    users.forEach((user, index) => {
      const li = document.createElement('li')
      li.className = 'modal-dialog-mention-item'
      if (index === 0) li.classList.add('active')

      const avatar = user.avatar_url
        ? `<img src="${user.avatar_url}" width="20" height="20" class="avatar" />`
        : ''
      li.innerHTML = `${avatar}<span class="modal-dialog-mention-name">${user.name}</span>`

      li.addEventListener('mouseenter', () => {
        dropdown.querySelectorAll('.active').forEach((el) => el.classList.remove('active'))
        li.classList.add('active')
      })
      li.addEventListener('mousedown', (e) => e.preventDefault())
      li.addEventListener('click', () => {
        input.value = `@${user.name}: `
        dropdown.style.display = 'none'
        // Move focus to next input
        const allInputs = Array.from(this.dialog.querySelectorAll('[data-param-name]'))
        const currentIdx = allInputs.indexOf(input)
        if (currentIdx >= 0 && currentIdx < allInputs.length - 1) {
          allInputs[currentIdx + 1].focus()
        }
      })
      dropdown.appendChild(li)
    })

    dropdown.style.display = 'block'
  }

  _moveMentionActive(dropdown, direction) {
    const items = Array.from(dropdown.querySelectorAll('.modal-dialog-mention-item'))
    if (items.length === 0) return
    const activeIdx = items.findIndex((el) => el.classList.contains('active'))
    items.forEach((el) => el.classList.remove('active'))
    let next = activeIdx + direction
    if (next < 0) next = items.length - 1
    if (next >= items.length) next = 0
    items[next].classList.add('active')
    items[next].scrollIntoView({ block: 'nearest' })
  }

  _autoResize(textarea) {
    textarea.style.height = 'auto'
    const lineHeight = parseFloat(getComputedStyle(textarea).lineHeight) || 20
    const maxHeight = lineHeight * 5
    textarea.style.height = `${Math.min(textarea.scrollHeight, maxHeight)}px`
    if (textarea.scrollHeight > maxHeight) {
      textarea.style.overflow = 'auto'
    } else {
      textarea.style.overflow = 'hidden'
    }
  }

  _handleKeydown(event) {
    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
      this.hide()
      this.onCancel()
    }
  }
}
