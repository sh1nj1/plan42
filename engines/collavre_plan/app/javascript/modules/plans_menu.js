// Plans menu functionality
// Delegate clicks once: workspace navigation preserves the GNB across turbo:load.

import { notifyPopupOpen, onOtherPopupOpen } from 'collavre/lib/gnb_popup_manager'

const POPUP_ID = 'plans-menu'
const loadedAreas = new WeakSet()

onOtherPopupOpen(POPUP_ID, function() {
  const area = document.getElementById('plans-list-area')
  if (area) area.style.display = 'none'
})

document.addEventListener('click', function(event) {
  if (!event.target.closest('.plans-menu-btn')) return

  const area = document.getElementById('plans-list-area')
  if (!area) return

  if (area.style.display !== 'none') {
    area.style.display = 'none'
    return
  }

  notifyPopupOpen(POPUP_ID)
  area.style.display = 'block'
  if (loadedAreas.has(area)) return

  const timeline = document.getElementById('plans-timeline')
  const plansUrl = area.dataset.plansUrl || '/plans.json'
  fetch(plansUrl)
    .then(function(r) { return r.json() })
    .then(function(plans) {
      if (timeline) { timeline.dataset.plans = JSON.stringify(plans) }
      if (window.initPlansTimeline && timeline) {
        window.initPlansTimeline(timeline)
      }
      loadedAreas.add(area)
    })
})
