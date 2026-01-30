import CommonPopup from '../lib/common_popup'
import { getCaretClientRect } from '../utils/caret_position'

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
        insert(command)
        popupMenu.hide()
        textarea.focus()
      }
    })

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
      const before = textarea.value.slice(0, pos)
      const after = textarea.value.slice(pos)
      const replaced = before.replace(/\/[^\s/]*$/, `${command.label} `)
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

    textarea.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    textarea.addEventListener('input', function () {
      const pos = textarea.selectionStart
      const before = textarea.value.slice(0, pos)
      const match = before.match(/\/([^\s/]*)$/)
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
