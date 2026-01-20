// Plans menu functionality
// Handles the plans menu button click and lazy-loads plans data

let initialized = false

function initPlansMenu() {
  if (initialized) return
  initialized = true

  document.addEventListener('turbo:load', function() {
    const btns = document.querySelectorAll('.plans-menu-btn')
    const area = document.getElementById('plans-list-area')
    let loaded = false
    const timeline = document.getElementById('plans-timeline')

    btns.forEach(function(btn) {
      btn.addEventListener('click', function() {
        if (area.style.display === 'none') {
          area.style.display = 'block'
          if (!loaded) {
            fetch('/plans.json')
              .then(function(r) { return r.json() })
              .then(function(plans) {
                if (timeline) { timeline.dataset.plans = JSON.stringify(plans) }
                if (window.initPlansTimeline && timeline) {
                  window.initPlansTimeline(timeline)
                }
                loaded = true
              })
          }
        } else {
          area.style.display = 'none'
        }
      })
    })
  })
}

initPlansMenu()
