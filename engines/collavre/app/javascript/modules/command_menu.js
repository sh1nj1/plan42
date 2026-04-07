import CommonPopup from '../lib/common_popup'
import { getCaretClientRect } from '../utils/caret_position'
import CommandArgsForm from './command_args_form'

let commandMenuInitialized = false

if (!commandMenuInitialized) {
  commandMenuInitialized = true

  document.addEventListener('turbo:load', function () {
    const textarea = document.querySelector('#new-comment-form textarea')
    const menu = document.getElementById('command-menu')
    const popup = document.getElementById('comments-popup')
    if (!textarea || !menu || !popup) return

    const list = menu.querySelector('[data-popup-list]')
    const commandCache = new Map()

    const argsForm = new CommandArgsForm({
      labels: {
        submit: menu.dataset.formSubmit || 'OK',
        cancel: menu.dataset.formCancel || 'Cancel'
      },
      onSubmit: (commandText) => {
        textarea.value = commandText
        textarea.setSelectionRange(commandText.length, commandText.length)
        textarea.focus()
        textarea.dispatchEvent(new Event('input', { bubbles: true }))
      },
      onCancel: () => {
        textarea.focus()
      }
    })

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      renderItem: (command) => {
        const aliasLabel = command.aliases?.length
          ? `<span class="command-aliases">(${command.aliases.join(', ')})</span>`
          : ''
        const args = command.args ? `<span class="command-args">${command.args}</span>` : ''
        const description = command.description
          ? `<div class="command-description">${command.description}</div>`
          : ''
        return `
          <div class="command-item">
            <span class="command-label">${command.label}</span>
            ${aliasLabel}
            ${args}
          </div>
          ${description}
        `
      },
      onSelect: (command) => {
        if (command.type === 'popup' && command.popup_type === 'creative_picker') {
          openCreativePicker(textarea)
          popupMenu.hide()
          return
        }

        // If the command has an input schema, show the args form instead
        if (command.input_schema?.length) {
          popupMenu.hide()
          clearCommandText()
          const rect = textarea.getBoundingClientRect()
          argsForm.show(command, rect)
          return
        }

        insert(command)
        popupMenu.hide()
        textarea.focus()
      }
    })

    function clearCommandText() {
      const pos = textarea.selectionStart
      const after = textarea.value.slice(pos)
      const before = textarea.value.slice(0, pos)
      const cleaned = before.replace(/^\/\S*\s*/, '')
      textarea.value = cleaned + after
      textarea.setSelectionRange(cleaned.length, cleaned.length)
    }

    function fetchCommands(creativeId) {
      if (!creativeId) return Promise.resolve([])
      if (commandCache.has(creativeId)) return Promise.resolve(commandCache.get(creativeId))

      return fetch(`/creatives/${creativeId}/comments/commands`, { headers: { Accept: 'application/json' } })
        .then((response) => (response.ok ? response.json() : []))
        .then((data) => {
          const list = Array.isArray(data) ? data : []
          commandCache.set(creativeId, list)
          return list
        })
        .catch(() => [])
    }

    function insert(command) {
      const pos = textarea.selectionStart
      const after = textarea.value.slice(pos)
      // Since "/" is always at the start, replace from beginning
      const replaced = `${command.label} `
      textarea.value = replaced + after
      textarea.setSelectionRange(replaced.length, replaced.length)
    }

    function hide() {
      popupMenu.hide()
    }

    function show(commands, query) {
      if (!commands || commands.length === 0) {
        hide()
        return
      }

      const lowered = query.toLowerCase()
      const filtered = commands.filter((command) => {
        if (!lowered) return true
        const name = command.name?.toLowerCase?.() || ''
        const aliases = (command.aliases || []).map((alias) => alias.toLowerCase())
        return name.includes(lowered) || aliases.some((alias) => alias.replace('/', '').includes(lowered))
      })

      if (filtered.length === 0) {
        hide()
        return
      }

      popupMenu.setItems(filtered)
      const caretRect = getCaretClientRect(textarea) || textarea.getBoundingClientRect()
      popupMenu.showAt(caretRect)
    }

    function openCreativePicker(textarea) {
      const modal = document.getElementById('link-creative-modal')
      if (!modal) return

      const controller = window.Stimulus?.getControllerForElementAndIdentifier(modal, 'link-creative')
      if (!controller) return

      // Clear the command text (e.g. "/crea", "/creative") from textarea
      clearCommandText()

      const caretRect = getCaretClientRect(textarea) || textarea.getBoundingClientRect()
      controller.open(
        caretRect,
        (item) => {
          // Insert markdown link at cursor position
          const link = `[${item.label}](/creatives/${item.id})`
          const curPos = textarea.selectionStart
          const beforeCur = textarea.value.slice(0, curPos)
          const afterCur = textarea.value.slice(curPos)
          textarea.value = beforeCur + link + ' ' + afterCur
          const newPos = curPos + link.length + 1
          textarea.setSelectionRange(newPos, newPos)
          textarea.focus()
        },
        () => {
          textarea.focus()
        }
      )
    }

    textarea.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    textarea.addEventListener('input', function () {
      // If args form is open, don't show command menu
      if (argsForm.isOpen()) return

      const pos = textarea.selectionStart
      const before = textarea.value.slice(0, pos)
      // Only trigger when "/" is at the very beginning of the message
      const match = before.match(/^\/([^\s/]*)$/)
      if (!match) {
        hide()
        return
      }

      const creativeId = popup.dataset.creativeId
      const query = match[1]

      fetchCommands(creativeId)
        .then((commands) => show(commands, query))
    })
  })
}
