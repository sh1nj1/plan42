import CommonPopup from '../lib/common_popup'
import { caretAnchor } from '../utils/caret_position'

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
    let requestId = 0

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      renderItem: (user) => `<div class="mention-item"><img src="${user.avatar_url}" width="20" height="20" class="avatar" /> ${user.name}</div>`,
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
      popupMenu.showAt(caretAnchor(textarea))
    }

    textarea.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    function search(q, id) {
      const creativeId = popup?.dataset.creativeId
      const url = new URL('/users/search', window.location.origin)
      url.searchParams.set('q', q)
      if (creativeId) url.searchParams.set('creative_id', creativeId)
      fetch(url, { headers: { Accept: 'application/json' } })
        .then((r) => r.ok ? r.json() : [])
        .then((users) => {
          if (id === requestId && creativeId === popup?.dataset.creativeId) show(users)
        })
        .catch(() => {})
    }

    textarea.addEventListener('input', function () {
      clearTimeout(fetchTimer)
      const id = ++requestId
      const before = textarea.value.slice(0, textarea.selectionStart)
      const m = before.match(/@([^\s@]*)$/)
      hide()
      if (!m) return
      const q = m[1]
      if (q.length === 0) search(q, id)
      else fetchTimer = setTimeout(() => search(q, id), 200)
    })
  })
}
