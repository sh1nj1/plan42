// Inbox panel functionality
// Manages the inbox slide panel UI with pagination and touch gestures

let initialized = false

function initInboxPanel() {
  if (initialized) return
  initialized = true

  document.addEventListener('turbo:load', function() {
    const btns = document.querySelectorAll('.inbox-menu-btn')
    const panel = document.getElementById('inbox-panel')
    const list = document.getElementById('inbox-list')
    const closeBtn = document.getElementById('close-inbox')
    const toggle = document.getElementById('toggle-inbox-read')

    if (toggle && localStorage.getItem('inboxShowRead') === '1') {
      toggle.checked = true
    }

    function updateInboxBadge() {
      const badges = ['desktop-inbox-badge', 'mobile-inbox-badge']
        .map(function(id) { return document.getElementById(id) })
        .filter(function(el) { return el })
      if (badges.length === 0) return
      fetch('/inbox/count')
        .then(r => r.json())
        .then(data => {
          badges.forEach(function(badge) {
            if (data.count > 0) {
              badge.textContent = data.count
              badge.style.display = 'inline-block'
            } else {
              badge.textContent = ''
              badge.style.display = 'none'
            }
          })
        })
    }

    let inboxNextPage = null
    let inboxIsLoading = false

    function fetchInboxPage(page, append) {
      if (!list) return Promise.resolve()
      inboxIsLoading = true
      const params = new URLSearchParams()
      params.set('page', page)
      if (toggle && toggle.checked) {
        params.set('show', 'all')
      }
      return fetch('/inbox?' + params.toString(), { headers: { 'Accept': 'application/json' } })
        .then(function(r) { return r.json() })
        .then(function(data) {
          let container = list.querySelector('#inbox-items')
          if (!container) {
            container = document.createElement('div')
            container.id = 'inbox-items'
            list.innerHTML = ''
            list.appendChild(container)
          } else if (!append) {
            container.innerHTML = ''
          }

          if (data.empty && !append) {
            container.innerHTML = ''
            const emptyDiv = document.createElement('div')
            emptyDiv.className = 'inbox-empty'
            emptyDiv.textContent = list ? (list.dataset.emptyText || '') : ''
            container.appendChild(emptyDiv)
          } else if (data.items_html) {
            if (!append) {
              container.innerHTML = data.items_html
            } else {
              container.insertAdjacentHTML('beforeend', data.items_html)
            }
          }

          inboxNextPage = data.next_page
          container.dataset.nextPage = data.next_page || ''
          attachActions()
          updateInboxBadge()
        })
        .finally(function() {
          inboxIsLoading = false
        })
    }

    function loadInbox() {
      if (!list) return Promise.resolve()
      inboxNextPage = null
      inboxIsLoading = false
      list.textContent = list.dataset.loadingText || ''
      return fetchInboxPage(1, false)
    }

    function maybeLoadMore() {
      if (!panel) return
      if (inboxIsLoading) return
      if (!inboxNextPage) return
      if (panel.scrollTop + panel.clientHeight >= panel.scrollHeight - 50) {
        fetchInboxPage(inboxNextPage, true)
      }
    }

    function getCsrfToken() {
      const meta = document.querySelector('meta[name="csrf-token"]')
      return meta ? meta.content : ''
    }

    function attachActions() {
      document.querySelectorAll('.inbox-item .mark-read').forEach(function(b) {
        b.onclick = function() {
          fetch('/inbox/' + b.dataset.id, {
            method: 'PATCH',
            headers: {
              'Content-Type': 'application/json',
              'X-CSRF-Token': getCsrfToken()
            },
            body: JSON.stringify({ state: 'read' })
          }).then(loadInbox)
        }
      })
      document.querySelectorAll('.inbox-item .mark-unread').forEach(function(b) {
        b.onclick = function() {
          fetch('/inbox/' + b.dataset.id, {
            method: 'PATCH',
            headers: {
              'Content-Type': 'application/json',
              'X-CSRF-Token': getCsrfToken()
            },
            body: JSON.stringify({ state: 'new' })
          }).then(loadInbox)
        }
      })
      document.querySelectorAll('.inbox-item .delete-item').forEach(function(b) {
        b.onclick = function() {
          fetch('/inbox/' + b.dataset.id, {
            method: 'DELETE',
            headers: { 'X-CSRF-Token': getCsrfToken() }
          }).then(loadInbox)
        }
      })
      document.querySelectorAll('.inbox-item .item-link').forEach(function(a) {
        // Use onclick assignment to prevent duplicate listeners on pagination append
        a.onclick = function() {
          localStorage.setItem('inboxOpen', '1')
          const item = a.closest('.inbox-item')
          if (item && item.dataset.id) {
            fetch('/inbox/' + item.dataset.id, {
              method: 'PATCH',
              headers: {
                'Content-Type': 'application/json',
                'X-CSRF-Token': getCsrfToken()
              },
              body: JSON.stringify({ state: 'read' }),
              keepalive: true
            })
          }
        }
      })
    }

    function openPanel() {
      if (!panel) return
      panel.classList.add('open')
      localStorage.setItem('inboxOpen', '1')
      loadInbox()
      document.body.classList.add('no-scroll')
    }

    function closePanel() {
      if (!panel) return
      panel.classList.remove('open')
      localStorage.removeItem('inboxOpen')
      document.body.classList.remove('no-scroll')
    }

    let startX = null
    if (panel) {
      panel.addEventListener('touchstart', function(e) {
        startX = e.touches[0].clientX
      })
      panel.addEventListener('touchend', function(e) {
        if (startX !== null) {
          const diffX = e.changedTouches[0].clientX - startX
          if (diffX > 50) {
            closePanel()
          }
        }
        startX = null
      })
      panel.addEventListener('scroll', maybeLoadMore)
    }

    btns.forEach(function(btn) {
      if (panel) {
        btn.addEventListener('click', function() {
          if (panel.classList.contains('open')) {
            closePanel()
          } else {
            openPanel()
          }
        })
      }
    })
    if (closeBtn) { closeBtn.addEventListener('click', closePanel) }
    if (toggle) {
      toggle.addEventListener('change', function() {
        localStorage.setItem('inboxShowRead', toggle.checked ? '1' : '0')
        loadInbox()
      })
    }

    updateInboxBadge()

    if (panel && btns.length > 0 && localStorage.getItem('inboxOpen') === '1') {
      panel.classList.add('open')
      loadInbox()
    } else if (btns.length === 0) {
      localStorage.removeItem('inboxOpen')
    }
  })
}

initInboxPanel()
