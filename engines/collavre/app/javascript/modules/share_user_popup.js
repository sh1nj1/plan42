import CommonPopup from '../lib/common_popup'

let sharePopupInitialized = false

if (!sharePopupInitialized) {
  sharePopupInitialized = true

  document.addEventListener('turbo:load', function () {
    const input = document.getElementById('share-user-email')
    const menu = document.getElementById('share-user-suggestions')
    const modal = document.getElementById('share-creative-modal')
    const closeBtn = document.getElementById('close-share-modal')

    if (!input || !menu) return

    const list = menu.querySelector('.mention-results') || menu.querySelector('.common-popup-list')
    let fetchTimer

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      renderItem: (user) => `<div class="mention-item"><img src="${user.avatar_url || ''}" width="20" height="20" class="avatar" /> ${user.name} <span style="opacity:0.7">${user.email || ''}</span></div>`,
      onSelect: (user) => {
        input.value = user.email || user.name
        popupMenu.hide()
        input.focus()
        input.dispatchEvent(new Event('input', { bubbles: true }))
        input.dispatchEvent(new Event('blur', { bubbles: true }))
      },
    })

    function hide() {
      popupMenu.hide()
    }

    function show(users) {
      if (!users || users.length === 0) {
        hide()
        return
      }
      popupMenu.setItems(users)
      popupMenu.showAt(input.getBoundingClientRect())
    }

    input.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    input.addEventListener('input', function () {
      const term = input.value.trim()
      if (!term) {
        hide()
        return
      }
      clearTimeout(fetchTimer)
      fetchTimer = setTimeout(function () {
        const url = new URL('/users/search', window.location.origin)
        url.searchParams.set('q', term)
        if (modal?.dataset?.creativeId) {
          url.searchParams.set('creative_id', modal.dataset.creativeId)
        }
        fetch(url, { headers: { Accept: 'application/json' } })
          .then(function (r) { return r.ok ? r.json() : [] })
          .then(show)
          .catch(function () { })
      }, 200)
    })

    input.addEventListener('blur', function () {
      setTimeout(hide, 150)
    })

    closeBtn?.addEventListener('click', hide)
    modal?.addEventListener('click', function (event) {
      if (event.target === modal) hide()
    })
  })
}
