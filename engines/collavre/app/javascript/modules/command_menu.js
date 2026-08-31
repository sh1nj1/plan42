import CommonPopup from '../lib/common_popup'
import { caretAnchor } from '../utils/caret_position'
import CommandArgsForm from './command_args_form'
import { openCreativeLinkPicker } from './creative_link_picker'

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
    let skipNextMenuInput = false

    const argsForm = new CommandArgsForm({
      container: popup,
      creativeIdFn: () => popup.dataset.creativeId,
      contextValuesFn: () => ({
        // Prefer the effective origin id (what comments/topics controllers
        // operate on). For linked creatives, popup.dataset.creativeId is the
        // wrapper row id, but the server resolves through effective_origin —
        // MCP tools expect the same effective id.
        creative_id: popup.dataset.effectiveCreativeId || popup.dataset.creativeId || null,
        topic_id: currentTopicIdFromController(popup) || null
      }),
      labels: {
        submit: menu.dataset.formSubmit || 'OK',
        cancel: menu.dataset.formCancel || 'Cancel'
      },
      onSubmit: (commandText) => {
        popupMenu.hide()
        // clearCommandText() stripped only the "/" token, so anything still in
        // the box is the draft the user had typed before opening the menu. The
        // command is submitted on its own, so the draft cannot ride along with
        // it — hand it to the form controller, which puts it back once the send
        // settles, rather than dropping it on the floor here.
        const draft = textarea.value
        if (draft.trim()) {
          textarea.dispatchEvent(new CustomEvent('comments--form:stash-draft', {
            bubbles: true,
            detail: { draft }
          }))
        }
        textarea.value = commandText
        // Keep the normal input listeners (drafts, resize, submit state) in
        // sync without treating this programmatic command as a new typeahead
        // query. A schema command with no entered values is just "/name", so
        // the command menu would otherwise reopen as soon as the form closes.
        skipNextMenuInput = true
        textarea.dispatchEvent(new Event('input', { bubbles: true }))
        // Trigger form submission directly
        const submitBtn = document.querySelector('#new-comment-form [data-comments--form-target="submit"]')
        if (submitBtn) {
          // Keep focus out of the textarea while its value is still the command
          // being sent. The form announces settlement after success/failure
          // cleanup, so typing cannot append to the in-flight command.
          popup.addEventListener('comments--form:submit-settled', () => textarea.focus(), { once: true })
          submitBtn.click()
        }
      },
      onCancel: () => {
        popupMenu.hide()
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
          argsForm.show(command)
          return
        }

        insert(command)
        popupMenu.hide()
        textarea.focus()
      }
    })

    function currentTopicIdFromController(popupEl) {
      // Prefer the form controller's locally-cached topic id — the same value
      // used when submitting a comment. It is set from the
      // `comments--topics:change` event, so it reflects the user's actual
      // selection after restoreSelection rather than a stale URL deep-link.
      const formCtrl = window.Stimulus?.getControllerForElementAndIdentifier(popupEl, 'comments--form')
      if (formCtrl) {
        const id = formCtrl.currentTopicId || formCtrl._mainTopicId
        if (id) return String(id)
      }
      // Topics may not have loaded yet (form hasn't received any change event).
      // Fall back to mainTopicId only — never topicsCtrl.currentTopicId, whose
      // getter prioritizes window.location.search?topic_id= even when that
      // topic does not belong to the current creative.
      const topicsCtrl = window.Stimulus?.getControllerForElementAndIdentifier(popupEl, 'comments--topics')
      if (!topicsCtrl) return ''
      return topicsCtrl.mainTopicId ? String(topicsCtrl.mainTopicId) : ''
    }

    function clearCommandText() {
      const pos = textarea.selectionStart
      const after = textarea.value.slice(pos)
      const before = textarea.value.slice(0, pos)
      const cleaned = before.replace(/^\/\S*\s*/, '')
      textarea.value = cleaned + after
      textarea.setSelectionRange(cleaned.length, cleaned.length)
    }

    // Cached by creative id, and cached as the *promise* rather than its result:
    // the list is fetched on every keystroke, so caching only after the response
    // lands would fire one request per character of "/task" before the first one
    // returns. In-flight callers share the request instead.
    function fetchCommands(creativeId) {
      if (!creativeId) return Promise.resolve([])
      if (commandCache.has(creativeId)) return commandCache.get(creativeId)

      const request = fetch(`/creatives/${creativeId}/comments/commands`, { headers: { Accept: 'application/json' } })
        .then((response) => (response.ok ? response.json() : []))
        .then((data) => (Array.isArray(data) ? data : []))
        .catch(() => {
          // Don't leave a failed lookup cached — the next keystroke retries.
          commandCache.delete(creativeId)
          return []
        })

      commandCache.set(creativeId, request)
      return request
    }

    function insert(command) {
      const pos = textarea.selectionStart
      const after = textarea.value.slice(pos)
      // Since "/" is always at the start, replace from beginning
      const replaced = `${command.label} `
      textarea.value = replaced + after
      textarea.setSelectionRange(replaced.length, replaced.length)
    }

    function show(commands, query) {
      if (!commands || commands.length === 0) {
        popupMenu.hide()
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
        popupMenu.hide()
        return
      }

      popupMenu.setItems(filtered)
      popupMenu.showAt(caretAnchor(textarea))
    }

    function openCreativePicker(textarea) {
      openCreativeLinkPicker(textarea, {
        triggerRange: { start: 0, end: textarea.selectionStart },
      })
    }

    textarea.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    // Bumped by every input event, so a lookup that resolves after the user has
    // typed on (or deleted the "/" entirely) is dropped instead of rendering the
    // menu from a query that no longer matches the box — the late response would
    // otherwise pop the menu back up over an unrelated draft.
    let queryToken = 0

    textarea.addEventListener('input', function () {
      const token = ++queryToken
      if (skipNextMenuInput) {
        skipNextMenuInput = false
        popupMenu.hide()
        return
      }

      // If args form is open, don't show command menu
      if (argsForm.isOpen()) return

      const pos = textarea.selectionStart
      const before = textarea.value.slice(0, pos)
      // Only trigger when "/" is at the very beginning of the message
      const match = before.match(/^\/([^\s/]*)$/)
      if (!match) {
        popupMenu.hide()
        return
      }

      const creativeId = popup.dataset.creativeId
      const query = match[1]

      fetchCommands(creativeId)
        .then((commands) => {
          if (token !== queryToken) return
          show(commands, query)
        })
    })
  })
}
