import CommonPopup from '../lib/common_popup'
import { getCaretClientRect } from '../utils/caret_position'
import { escapeHtmlText, escapeHtmlAttr } from '../utils/html_escape'

let mentionMenuInitialized = false

if (!mentionMenuInitialized) {
  mentionMenuInitialized = true

  document.addEventListener('turbo:load', function () {
    const textarea = document.querySelector('#new-comment-form textarea')
    const menu = document.getElementById('mention-menu')
    const popup = document.getElementById('comments-popup')
    if (!textarea || !menu) return

    const list = menu.querySelector('.mention-results')
    let fetchTimer

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      // Both fields are user-controlled: a display name goes into element text,
      // an avatar URL into a double-quoted attribute — hence the two escapers.
      renderItem: (user) => `<div class="mention-item"><img src="${escapeHtmlAttr(user.avatar_url)}" width="20" height="20" class="avatar" /> ${escapeHtmlText(user.name)}</div>`,
      onSelect: (user) => {
        insert(user)
        popupMenu.hide()
        textarea.focus()
      },
    })

    function insert(user) {
      const pos = textarea.selectionStart
      const before = textarea.value.slice(0, pos).replace(/@[^@\s]*$/, `@${user.name}: `)
      textarea.value = before + textarea.value.slice(pos)
      textarea.setSelectionRange(before.length, before.length)
    }

    function hide() {
      popupMenu.hide()
    }

    function show(users) {
      if (!users || users.length === 0) {
        hide()
        return
      }
      popupMenu.setItems(users)
      const caretRect = getCaretClientRect(textarea) || textarea.getBoundingClientRect()
      popupMenu.showAt(caretRect)
    }

    textarea.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    textarea.addEventListener('input', function () {
      const pos = textarea.selectionStart
      const before = textarea.value.slice(0, pos)
      const m = before.match(/@([^\s@]*)$/)
      if (m) {
        const q = m[1]
        if (q.length === 0) { hide(); return }
        clearTimeout(fetchTimer)
        fetchTimer = setTimeout(function () {
          const url = new URL('/users/search', window.location.origin)
          url.searchParams.set('q', q)
          if (popup && popup.dataset.creativeId) {
            url.searchParams.set('creative_id', popup.dataset.creativeId)
          }
          fetch(url, { headers: { Accept: 'application/json' } })
            .then(function (r) { return r.ok ? r.json() : [] })
            .then(show)
            .catch(function () { })
        }, 200)
      } else {
        hide()
      }
    })
  })
}
