import { Controller } from '@hotwired/stimulus'
import csrfFetch from '../lib/api/csrf_fetch'
import { animate, confetti, sleep, EASE, HOLD, FADE_OUT } from '../modules/notice_bar/motion'
import { buildStrip, buildPeeks, CHECK_SVG } from '../modules/notice_bar/view'
import NoticeRefresh from '../modules/notice_bar/refresh'
import NoticeSheet from '../modules/notice_bar/sheet'
import Toasts from '../modules/notice_bar/toasts'
import { Spotlight, findTarget, rememberPendingSpotlight, takePendingSpotlight } from '../modules/notice_bar/spotlight'
import { parseJSON, readSession, writeSession } from '../modules/notice_bar/storage'

// Top notice bar: one strip with the remaining notices peeking behind it.
// Clicking the strip morphs it into a detail sheet; × dismisses it (missions
// snooze instead, since they stay until done). The server owns the list — it
// arrives in the payload target on page load and again over the user's inbox
// stream whenever a mission completes — and this controller only animates the
// difference between what is on screen and what arrived.

const CELEBRATION_MS = 1500
const FIRST_DROP_DELAY_MS = 300
const SPOTLIGHT_RETRIES = 10
const LAST_TOP_KEY = 'collavre:notice-top'

const STRIP_MOTION = {
  drop: [[{ transform: 'translateY(-110%)' }, { transform: 'none' }], { duration: 520, easing: EASE.spring }],
  rise: [[{ transform: 'translateY(8px) scale(.97)', opacity: 0.4, filter: 'brightness(.8)' }, { transform: 'none', opacity: 1, filter: 'none' }], { duration: 360, easing: EASE.out }],
  flipIn: [[{ transform: 'rotateX(90deg)' }, { transform: 'none' }], { duration: 300, easing: 'cubic-bezier(.2,.8,.3,1.2)' }],
}
const EXIT_UP = [[{ transform: 'none', opacity: 1 }, { transform: 'translateY(-100%)', opacity: 0 }], { duration: 280, easing: 'ease-in', fill: 'forwards' }, FADE_OUT]

export default class extends Controller {
  static targets = ['stack', 'toasts', 'flash', 'payload']
  static values = { url: String, feedUrl: String, refreshAt: String, i18n: Object }

  initialize() {
    this.queue = []
    this.removed = new Set()
    this.snoozed = new Set()
    this.work = Promise.resolve()
    this.busy = false
    this.deferred = []
  }

  connect() {
    this.feedRefresh = new NoticeRefresh(this.feedUrlValue, (items, current) => this.applyRefresh(items, current))
    this.feedRefresh.schedule(this.refreshAtValue)
    this.beforeCache = () => {
      this.clearTransientUI()
      this.feedRefresh?.destroy()
      for (const payload of this.payloadTargets) {
        payload.dataset.items = JSON.stringify(parseJSON(payload.dataset.items, []).filter((item) => !this.removed.has(item.key)))
        delete payload.dataset.completion
      }
    }
    document.addEventListener('turbo:before-cache', this.beforeCache)
  }

  applyRefresh(items, current) {
    return this.run(() => {
      // A newer payload can arrive while this job waits for an animation.
      if (!current()) return undefined
      for (const key of this.snoozed) this.removed.delete(key)
      this.snoozed.clear()
      return this.reconcile(items)
    })
  }

  disconnect() {
    document.removeEventListener('turbo:before-cache', this.beforeCache)
    this.clearTransientUI()
    this.feedRefresh?.destroy()
  }

  clearTransientUI() {
    this.toastLayer?.destroy()
    this.sheetView?.destroy()
    this.spot?.clear()
    this.toastLayer = this.sheetView = this.spot = null
    this.toastsTarget.replaceChildren()
    if (this.strip) this.strip.style.visibility = ''
  }

  // Targets connect before connect() runs, so collaborators are created lazily.
  get toasts() {
    return (this.toastLayer ||= new Toasts(this.toastsTarget))
  }

  get sheet() {
    if (!this.sheetView) {
      this.sheetView = new NoticeSheet(this.i18nValue)
      this.sheetView.backdrop.addEventListener('click', () => this.act(() => this.closeDetail()))
    }
    return this.sheetView
  }

  get spotlight() {
    return (this.spot ||= new Spotlight())
  }

  get strip() {
    return this.stackTarget.querySelector('.notice-strip')
  }

  get t() {
    return this.i18nValue
  }

  flashTargetConnected(el) {
    this.toasts.adopt(el)
  }

  payloadTargetConnected(el) {
    this.feedRefresh?.invalidate()
    const items = parseJSON(el.dataset.items, [])
    const completion = parseJSON(el.dataset.completion, null)
    this.run(() => {
      this.receiveMutation(el.dataset)
      return this.reconcile(items, completion)
    })
  }

  receiveMutation({ changed, refreshAt }) {
    if (!changed) return
    const keys = parseJSON(changed, null)
    for (const key of Array.isArray(keys) ? keys : [changed]) {
      this.removed.delete(key)
      this.snoozed.delete(key)
    }
    this.scheduleRefresh(refreshAt)
    window.Turbo?.cache?.clear()
  }

  // Server updates queue behind any running animation; user input is dropped
  // while one plays so a double click cannot act on the next notice.
  run(job) {
    this.work = this.work.then(async () => {
      this.busy = true
      try { await job() } finally { this.busy = false }
    }).catch((error) => console.error('[notice-bar]', error))
    return this.work
  }

  act(job) {
    if (this.busy) return undefined
    return this.run(job)
  }

  stackClick(event) {
    if (event.target.closest('.notice-strip__close')) {
      event.stopPropagation()
      this.act(() => this.dismissTop())
    } else if (event.target.closest('.notice-strip')) {
      this.act(() => this.openDetail())
    }
  }

  stackKeydown(event) {
    if (!['Enter', ' '].includes(event.key) || !event.target.matches('.notice-strip')) return
    event.preventDefault()
    this.act(() => this.openDetail())
  }

  escape(event) {
    if (event.key !== 'Escape') return
    if (this.sheetView?.isOpen) this.act(() => this.closeDetail())
    else this.spot?.clear()
  }

  async reconcile(incoming, completion) {
    const items = incoming.filter((item) => !this.removed.has(item.key))
    if (!this.loaded) return this.firstRender(items)
    if (this.sheetView?.isOpen) {
      // Every completion keeps its celebration; plain updates only need the latest.
      if (!completion) this.deferred = this.deferred.filter(([, done]) => done)
      this.deferred.push([items, completion])
      return undefined
    }
    if (!completion) return this.applyItems(items)

    this.spotlight.clear()
    if (this.queue[0]?.key === completion.key) return this.celebrate(items, completion)
    await this.applyItems(items)
    this.toasts.show(completion.next_key ? this.t.mission_done_toast : this.t.group_done_toast)
    return undefined
  }

  // A new top notice drops in; a longer stack behind the same top bumps the count.
  async applyItems(items) {
    const oldTop = this.queue[0]?.key
    const oldLength = this.queue.length
    this.queue = items
    const newTop = items[0]?.key
    await this.renderStack(newTop && newTop !== oldTop ? 'drop' : 'none')
    if (newTop && newTop === oldTop && items.length > oldLength) this.bumpCount()
  }

  // Page loads re-render the bar; only drop it in when the top notice is new
  // to this tab, not on every navigation.
  async firstRender(items) {
    this.loaded = true
    this.queue = items
    const fresh = items[0] && readSession(LAST_TOP_KEY) !== items[0].key
    if (fresh) await sleep(FIRST_DROP_DELAY_MS)
    await this.renderStack(fresh ? 'drop' : 'none')
    this.resumeSpotlight()
  }

  async renderStack(mode = 'none') {
    const stack = this.stackTarget
    const oldHeight = stack.offsetHeight
    const [top, ...rest] = this.queue
    stack.replaceChildren(...(top ? [...buildPeeks(rest), buildStrip(top, { i18n: this.t, extra: rest.length })] : []))
    stack.style.paddingBottom = `${Math.min(rest.length, 2) * 5}px`
    const newHeight = stack.offsetHeight
    if (oldHeight !== newHeight) {
      animate(stack, [{ height: `${oldHeight}px` }, { height: `${newHeight}px` }], { duration: 320, easing: EASE.out }, HOLD)
    }
    if (top) writeSession(LAST_TOP_KEY, top.key)
    const motion = STRIP_MOTION[mode]
    if (top && motion) await animate(this.strip, ...motion)
  }

  bumpCount() {
    const spring = { duration: 400, easing: EASE.spring }
    animate(this.stackTarget.querySelector('.notice-strip__count'), [{ transform: 'scale(1.6)' }, { transform: 'scale(1)' }], spring, HOLD)
    animate(this.stackTarget.querySelector('.notice-peek--1'), [{ transform: 'translateY(12px)' }, { transform: 'translateY(5px)' }], spring, HOLD)
  }

  // One request at a time, so an Undo cannot overtake the snooze it reverts.
  // Resolves to whether the server accepted the change.
  post(key, action) {
    const url = `${this.urlValue.replace('__key__', encodeURIComponent(key))}/${action}`
    this.requests = (this.requests || Promise.resolve())
      .then(() => csrfFetch(url, { method: 'POST', headers: { Accept: 'application/json' } }))
      .then((response) => {
        if (response.ok) {
          this.feedRefresh?.invalidate()
          window.Turbo?.cache?.clear()
          this.scheduleRefresh(response.headers?.get('X-Notice-Snoozed-Until'))
        }
        return response.ok
      })
      .catch((error) => { console.error('[notice-bar]', action, error); return false })
    return this.requests
  }

  scheduleRefresh(deadline) {
    this.feedRefresh?.schedule(deadline)
    if (this.feedRefresh?.deadline) this.refreshAtValue = new Date(this.feedRefresh.deadline).toISOString()
  }

  async dismissTop() {
    const item = this.queue[0]
    if (!item) return
    const mission = item.kind === 'mission'
    if (!(await this.post(item.key, mission ? 'snooze' : 'dismiss'))) return
    this.queue.shift()
    this.removed.add(item.key)
    if (mission) this.snoozed.add(item.key)
    await animate(this.strip, [{ transform: 'none', opacity: 1 }, { transform: 'translateX(45%)', opacity: 0 }], { duration: 260, easing: EASE.exit, fill: 'forwards' }, FADE_OUT)
    await this.renderStack('rise')
    if (mission) this.toasts.show(this.t.snoozed, { label: this.t.undo, run: () => this.run(() => this.restore(item)) })
  }

  // The mission only comes back once the server has restored it (it may have
  // been completed meanwhile, in which case the broadcast already moved on).
  async restore(item) {
    if (!(await this.post(item.key, 'restore'))) return
    this.removed.delete(item.key)
    this.snoozed.delete(item.key)
    this.queue.unshift(item)
    await this.renderStack('drop')
  }

  async openDetail() {
    const item = this.queue[0]
    if (!item || !this.strip) return
    await this.sheet.open(item, this.strip)
    const { close, later, cta } = this.sheet.parts
    close.addEventListener('click', () => this.act(() => this.closeDetail()))
    later.addEventListener('click', () => this.act(() => this.closeDetail(() => this.dismissTop())))
    cta.addEventListener('click', () => this.act(() => this.closeDetail(() => this.followCta(item))))
  }

  // `then` runs before any payload that arrived while the sheet was open, so it
  // still acts on the notice the user was looking at.
  async closeDetail(then) {
    if (!this.sheetView?.isOpen) return
    await this.sheet.close(this.strip)
    if (then) await then()
    for (const payload of this.deferred.splice(0)) await this.reconcile(...payload)
  }

  async followCta(item) {
    if (item.kind === 'mission') return this.startMission(item)

    if (!(await this.post(item.key, 'complete'))) return
    this.removed.add(item.key)
    this.queue = this.queue.filter((queued) => queued.key !== item.key)
    await animate(this.strip, ...EXIT_UP)
    await this.renderStack('rise')
    if (item.cta_url) this.visit(item.cta_url)
    return undefined
  }

  startMission(item) {
    const target = findTarget(item.target)
    if (target) return this.spotlight.show(target, item.tip)
    const url = item.cta_url && new URL(item.cta_url, window.location.href)
    if (url && (['origin', 'pathname', 'search', 'hash'].some((part) => url[part] !== window.location[part]) || url.searchParams.get('open_comments') === 'true')) {
      rememberPendingSpotlight(item.key)
      return this.visit(item.cta_url)
    }
    return this.toasts.show(this.t.target_missing)
  }

  visit(url) {
    if (window.Turbo?.visit) window.Turbo.visit(url)
    else window.location.assign(url)
  }

  // Targets such as the chat composer can render after the bar, so retry briefly.
  async resumeSpotlight() {
    const item = this.queue.find((queued) => queued.key === takePendingSpotlight())
    if (!item) return
    for (let attempt = 0; attempt < SPOTLIGHT_RETRIES && this.element.isConnected; attempt++) {
      const target = findTarget(item.target)
      if (target) return this.spotlight.show(target, item.tip)
      await sleep(300)
    }
  }

  async celebrate(items, completion) {
    const strip = this.strip
    const next = items.find((item) => item.key === completion.next_key)
    this.markStripDone(strip, completion, next)
    if (!next) confetti(strip)
    await sleep(CELEBRATION_MS)

    this.queue = items
    if (next && items[0] === next) {
      await animate(strip, [{ transform: 'none' }, { transform: 'rotateX(-90deg)' }], { duration: 200, easing: 'ease-in', fill: 'forwards' }, FADE_OUT)
      await this.renderStack('flipIn')
    } else {
      await animate(strip, ...EXIT_UP)
      await this.renderStack(items.length ? 'rise' : 'none')
    }
  }

  markStripDone(strip, completion, next) {
    const part = (name) => strip.querySelector(`.notice-strip__${name}`)
    part('icon').innerHTML = CHECK_SVG
    part('tag').textContent = this.t.done_tag
    part('title').textContent = completion.done
    part('summary').textContent = next ? this.t.next.replace('%{title}', next.title) : this.t.all_done
    part('more').textContent = ''
    part('close')?.style.setProperty('visibility', 'hidden')
    animate(part('sweep'), [{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }], { duration: 450, easing: EASE.out, fill: 'forwards' }, [{ transform: 'scaleX(1)' }, { transform: 'scaleX(1)' }])
    animate(strip.querySelector('.notice-strip__check path'), [{ strokeDashoffset: 22 }, { strokeDashoffset: 0 }], { duration: 380, delay: 280, easing: 'ease-out', fill: 'forwards' }, [{ strokeDashoffset: 0 }, { strokeDashoffset: 0 }])
    animate(part('icon'), [{ transform: 'scale(.4)' }, { transform: 'scale(1.25)' }, { transform: 'scale(1)' }], { duration: 500, delay: 200, easing: 'ease-out' }, HOLD)
  }
}
