/**
 * Command Args Form — renders a dynamic form panel for slash command parameters.
 *
 * When a command with `input_schema` is selected from the command menu,
 * this module shows a form with labeled inputs, validates required fields,
 * and builds the final command string to insert into the textarea.
 */

const FORM_ID = 'command-args-form'

export default class CommandArgsForm {
  constructor({ onSubmit, onCancel, labels } = {}) {
    this.onSubmit = onSubmit || (() => {})
    this.onCancel = onCancel || (() => {})
    this.labels = labels || { submit: 'OK', cancel: 'Cancel' }
    this.command = null
    this.element = null
    this._handleKeydown = this._handleKeydown.bind(this)
  }

  /**
   * Show the args form for the given command.
   * @param {Object} command - Command object with label, input_schema, name, etc.
   * @param {DOMRect} anchorRect - Position anchor (e.g. textarea bounding rect).
   */
  show(command, anchorRect) {
    this.hide()
    if (!command?.input_schema?.length) return

    this.command = command
    this.element = this._buildForm(command)
    document.body.appendChild(this.element)
    this._position(anchorRect)

    // Focus the first input
    const firstInput = this.element.querySelector('input, select, textarea')
    if (firstInput) firstInput.focus()

    document.addEventListener('keydown', this._handleKeydown)
  }

  hide() {
    if (this.element) {
      this.element.remove()
      this.element = null
    }
    this.command = null
    document.removeEventListener('keydown', this._handleKeydown)
  }

  isOpen() {
    return !!this.element
  }

  // --- Private ---

  _buildForm(command) {
    const container = document.createElement('div')
    container.id = FORM_ID
    container.className = 'command-args-form'

    // Header
    const header = document.createElement('div')
    header.className = 'command-args-header'
    header.innerHTML = `<span class="command-args-title">${command.label}</span>`
    if (command.description) {
      header.innerHTML += `<span class="command-args-desc">${command.description}</span>`
    }
    container.appendChild(header)

    // Fields
    const fields = document.createElement('div')
    fields.className = 'command-args-fields'

    command.input_schema.forEach((param, index) => {
      const field = this._buildField(param, index)
      fields.appendChild(field)
    })
    container.appendChild(fields)

    // Actions
    const actions = document.createElement('div')
    actions.className = 'command-args-actions'

    const cancelBtn = document.createElement('button')
    cancelBtn.type = 'button'
    cancelBtn.className = 'command-args-cancel'
    cancelBtn.textContent = this.labels.cancel
    cancelBtn.addEventListener('click', () => {
      this.hide()
      this.onCancel()
    })

    const submitBtn = document.createElement('button')
    submitBtn.type = 'button'
    submitBtn.className = 'command-args-submit'
    submitBtn.textContent = this.labels.submit
    submitBtn.addEventListener('click', () => this._submit())

    actions.appendChild(cancelBtn)
    actions.appendChild(submitBtn)
    container.appendChild(actions)

    // Prevent clicks from dismissing (stop propagation to outside-click handlers)
    container.addEventListener('mousedown', (e) => e.stopPropagation())
    container.addEventListener('touchstart', (e) => e.stopPropagation())

    return container
  }

  _buildField(param, index) {
    const wrapper = document.createElement('div')
    wrapper.className = 'command-args-field'

    const label = document.createElement('label')
    label.className = 'command-args-label'
    label.textContent = param.name
    if (param.required) {
      const req = document.createElement('span')
      req.className = 'command-args-required'
      req.textContent = '*'
      label.appendChild(req)
    }
    wrapper.appendChild(label)

    let input
    if (param.enum && param.enum.length > 0) {
      input = document.createElement('select')
      input.className = 'command-args-input'
      if (!param.required) {
        const opt = document.createElement('option')
        opt.value = ''
        opt.textContent = '—'
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
      input.className = 'command-args-input'
      const optEmpty = document.createElement('option')
      optEmpty.value = ''
      optEmpty.textContent = '—'
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
      input.className = 'command-args-input'
      if (param.type === 'float') input.step = 'any'
    } else {
      input = document.createElement('input')
      input.type = 'text'
      input.className = 'command-args-input'
    }

    input.dataset.paramName = param.name
    input.dataset.paramType = param.type || 'string'
    input.dataset.paramRequired = param.required ? 'true' : 'false'
    if (param.description) input.placeholder = param.description

    // Submit on Enter from last field
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
    if (!this.element) return null

    const inputs = this.element.querySelectorAll('[data-param-name]')
    const values = {}
    let valid = true

    inputs.forEach((input) => {
      const name = input.dataset.paramName
      const required = input.dataset.paramRequired === 'true'
      const val = input.value.trim()

      input.classList.remove('command-args-error')

      if (required && !val) {
        input.classList.add('command-args-error')
        valid = false
        return
      }

      if (val) {
        values[name] = this._castValue(val, input.dataset.paramType)
      }
    })

    if (!valid) {
      // Focus first error field
      const errorField = this.element.querySelector('.command-args-error')
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
      const agent = values.agent_name.startsWith('@') ? values.agent_name : `@${values.agent_name}`
      parts.push(agent)
    }
    return parts.join(' ')
  }

  _buildWorkText(command, values) {
    const parts = [command.label]
    if (values.agent_name) {
      const agent = values.agent_name.startsWith('@') ? values.agent_name : `@${values.agent_name}`
      parts.push(agent)
    }
    if (values.context) parts.push(values.context)
    return parts.join(' ')
  }

  _buildCompressText(command, values) {
    const parts = [command.label]
    if (values.instructions) parts.push(values.instructions)
    return parts.join(' ')
  }

  _position(anchorRect) {
    if (!this.element || !anchorRect) return

    const boundsPadding = 8
    const formRect = this.element.getBoundingClientRect()
    let left = anchorRect.left
    let top = anchorRect.top - formRect.height - 4

    // If no room above, show below
    if (top < boundsPadding) {
      top = anchorRect.bottom + 4
    }

    // Clamp horizontal
    const maxLeft = window.innerWidth - formRect.width - boundsPadding
    left = Math.max(boundsPadding, Math.min(left, maxLeft))

    this.element.style.left = `${left}px`
    this.element.style.top = `${top}px`
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
