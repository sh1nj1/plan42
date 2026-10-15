import CommonPopup from '../lib/common_popup'
import { caretAnchor } from '../utils/caret_position'
import CommandArgsForm from './command_args_form'
import { openCreativeLinkPicker } from './creative_link_picker'

let commandMenuInitialized = false
let commandSubmissionSequence = 0

const escapeHtml = (value) => String(value)
  .replace(/&/g, '&amp;')
  .replace(/</g, '&lt;')
  .replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;')
  .replace(/'/g, '&#39;')

function renderCommand(command, moreLabel) {
  const aliasLabel = command.aliases?.length
    ? `<span class="command-aliases">(${command.aliases.join(', ')})</span>`
    : ''
  const args = command.args ? `<span class="command-args">${command.args}</span>` : ''
  const description = command.description
    ? `<div class="command-description">${escapeHtml(command.description)}</div>`
    : ''
  const details = command.details
    ? `<button type="button" class="command-more" data-command-more aria-expanded="false" aria-keyshortcuts="ArrowRight ArrowLeft">${escapeHtml(moreLabel)}</button>
       <div class="command-details" hidden>${escapeHtml(command.details)}</div>`
    : ''
  return `
    <div class="command-item">
      <span class="command-label">${command.label}</span>
      ${aliasLabel}
      ${args}
    </div>
    ${description}
    ${details}
  `
}

// "More" expands a tool's details in place. Handled in the capture phase so the
// item's own touchstart/touchend/click never see it and the command is not chosen.
// touchstart is left uncancelled so a swipe starting on the button still scrolls;
// touchend toggles only when the finger stayed within the tap threshold.
const TAP_THRESHOLD_PX = 10

function bindDetailsToggle(list, labels, onToggle) {
  let touchStartY = null
  const toggle = (event) => {
    const button = event.target.closest?.('[data-command-more]')
    if (!button || !list.contains(button)) return
    event.stopPropagation()
    if (event.type === 'touchstart') {
      touchStartY = event.touches[0].clientY
      return
    }
    if (event.type === 'touchend') {
      const moved = touchStartY === null ||
        Math.abs(event.changedTouches[0].clientY - touchStartY) >= TAP_THRESHOLD_PX
      touchStartY = null
      if (moved) return
    }
    event.preventDefault()
    setDetailsExpanded(button, button.getAttribute('aria-expanded') !== 'true', labels)
    onToggle()
  }
  for (const type of ['touchstart', 'touchend', 'click']) list.addEventListener(type, toggle, true)
}

function setDetailsExpanded(button, expanded, labels) {
  button.setAttribute('aria-expanded', String(expanded))
  button.textContent = expanded ? labels.less : labels.more
  button.nextElementSibling.hidden = !expanded
}

// Focus stays in the textarea while the menu is open (Tab/Enter select the
// active command), so the toggle is driven from there: ArrowRight expands the
// active command's details, ArrowLeft collapses them. Both only apply with a
// collapsed caret at the end of the text so they never steal caret movement.
function handleDetailsKey(event, list, labels) {
  if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return false
  if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return false
  const button = list.querySelector('.active [data-command-more]')
  if (!button) return false
  const expand = event.key === 'ArrowRight'
  if (expand === (button.getAttribute('aria-expanded') === 'true')) return false
  const { selectionStart, selectionEnd, value } = event.target
  if (selectionStart !== selectionEnd || selectionEnd !== value.length) return false
  event.preventDefault()
  setDetailsExpanded(button, expand, labels)
  return true
}

if (!commandMenuInitialized) {
  commandMenuInitialized = true

  document.addEventListener('turbo:load', function () {
    const textarea = document.querySelector('#new-comment-form textarea')
    const menu = document.getElementById('command-menu')
    const popup = document.getElementById('comments-popup')
    if (!textarea || !menu || !popup) return

    const list = menu.querySelector('[data-popup-list]')
    const labels = { more: menu.dataset.moreLabel || 'More', less: menu.dataset.lessLabel || 'Less' }
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
          const submissionId = String(++commandSubmissionSequence)
          let submissionStarted = false
          const markSubmission = (event) => { event.commandSubmissionId = submissionId }
          const onSubmissionStarted = (event) => {
            if (event.detail?.submissionId === submissionId) submissionStarted = true
          }
          // Keep focus out of the textarea while its value is still the command
          // being sent. The form announces settlement after success/failure
          // cleanup, so typing cannot append to the in-flight command.
          const onSubmissionSettled = (event) => {
            if (event.detail?.submissionId !== submissionId) return
            popup.removeEventListener('comments--form:submit-settled', onSubmissionSettled)
            const active = document.activeElement
            if (!active || active === document.body) textarea.focus()
          }
          submitBtn.addEventListener('click', markSubmission, { capture: true, once: true })
          popup.addEventListener('comments--form:submit-started', onSubmissionStarted)
          popup.addEventListener('comments--form:submit-settled', onSubmissionSettled)
          submitBtn.click()
          submitBtn.removeEventListener('click', markSubmission, true)
          popup.removeEventListener('comments--form:submit-started', onSubmissionStarted)
          if (!submissionStarted) {
            popup.removeEventListener('comments--form:submit-settled', onSubmissionSettled)
            textarea.focus()
          }
        }
      },
      onCancel: () => {
        popupMenu.hide()
        textarea.focus()
      }
    })

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      renderItem: (command) => renderCommand(command, labels.more),
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

    bindDetailsToggle(list, labels, () => popupMenu.reposition())

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
      if (popupMenu.isOpen() && handleDetailsKey(event, list, labels)) {
        popupMenu.reposition()
        return
      }
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
