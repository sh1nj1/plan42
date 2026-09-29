/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

const csrfFetch = jest.fn()

jest.unstable_mockModule('../../lib/api/csrf_fetch', () => ({
  default: csrfFetch,
}))

const { Application } = await import('@hotwired/stimulus')
const NoticeBarController = (await import('../notice_bar_controller')).default

const I18N = {
  region: 'Notices', more: 'More', close: 'Close', dismiss: 'Dismiss', later: 'Later', ok: 'OK',
  completed: 'Completed', done_tag: 'Done', next: 'Next: %{title}', all_done: 'All done',
  mission_done_toast: 'Mission done', group_done_toast: 'Group done', mission_hint: 'Stays until done',
  snoozed: 'Snoozed', undo: 'Undo', target_missing: 'Target missing',
}

const mission = (key, extra = {}) => ({
  key, kind: 'mission', icon: 'M', tag: 'Mission', title: `Mission ${key}`, summary: 'sum', body: 'body',
  cta: 'Start', cta_url: '/elsewhere', target: '#target', tip: 'Type here',
  steps: [{ title: 'one', state: 'done' }, { title: 'two', state: 'current' }], ...extra,
})
const notice = (key, extra = {}) => ({
  key, kind: 'announcement', icon: 'N', tag: 'News', title: `Notice ${key}`, summary: 'sum', body: 'body',
  cta: 'Read', cta_url: '/news', ...extra,
})

const TOP_KEY = 'collavre:notice-top'
const PENDING_KEY = 'collavre:notice-spotlight'

function payloadEl(items, completion) {
  const el = document.createElement('div')
  el.hidden = true
  el.setAttribute('data-notice-bar-target', 'payload')
  if (items !== undefined) el.setAttribute('data-items', typeof items === 'string' ? items : JSON.stringify(items))
  if (completion) el.setAttribute('data-completion', JSON.stringify(completion))
  return el
}

function makeVisible(el) {
  el.getClientRects = () => [{}]
  el.getBoundingClientRect = () => ({ left: 10, top: 10, bottom: 40, width: 100, height: 30 })
  return el
}

describe('NoticeBarController', () => {
  let application
  let zone
  let controller

  async function flush(ms = 0) {
    for (let i = 0; i < 4; i++) {
      await jest.advanceTimersByTimeAsync(ms)
      await controller?.work
    }
  }

  async function mount({ items = [], completion, flash, top } = {}) {
    if (top !== undefined) sessionStorage.setItem(TOP_KEY, top)
    zone = document.createElement('div')
    zone.className = 'notice-zone'
    zone.setAttribute('data-controller', 'notice-bar')
    zone.setAttribute('data-action', 'keydown@document->notice-bar#escape')
    zone.setAttribute('data-notice-bar-feed-url-value', '/user_notices')
    zone.setAttribute('data-notice-bar-url-value', '/user_notices/__key__')
    zone.setAttribute('data-notice-bar-i18n-value', JSON.stringify(I18N))
    zone.innerHTML = `
      <div class="notice-zone__stack" data-notice-bar-target="stack" data-action="click->notice-bar#stackClick keydown->notice-bar#stackKeydown" role="region"></div>
      <div class="notice-zone__toasts" data-notice-bar-target="toasts" aria-live="polite">
        ${flash ? `<div class="notice-toast" data-notice-bar-target="flash"><span>${flash}</span></div>` : ''}
      </div>`
    if (items !== null) zone.appendChild(payloadEl(items, completion))
    document.body.appendChild(zone)
    application = Application.start()
    application.register('notice-bar', NoticeBarController)
    await jest.advanceTimersByTimeAsync(0)
    controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
    await flush(400)
    return controller
  }

  const stack = () => zone.querySelector('.notice-zone__stack')
  const strip = () => zone.querySelector('.notice-strip')
  const sheetEl = () => document.querySelector('.notice-sheet')
  const toastText = () => zone.querySelector('.notice-zone__toasts').textContent.trim()
  const postedUrls = () => csrfFetch.mock.calls.map(([url]) => url)

  async function replacePayload(items, completion) {
    zone.querySelector('[data-notice-bar-target="payload"]')?.remove()
    zone.appendChild(payloadEl(items, completion))
    await jest.advanceTimersByTimeAsync(0)
  }

  async function openSheet() {
    strip().click()
    await flush()
    expect(sheetEl().hidden).toBe(false)
  }

  beforeEach(() => {
    jest.useFakeTimers()
    csrfFetch.mockReset()
    csrfFetch.mockResolvedValue({ ok: true })
    sessionStorage.clear()
    window.Turbo = { visit: jest.fn() }
    jest.spyOn(console, 'error').mockImplementation(() => {})
  })

  afterEach(async () => {
    window.history.replaceState({}, '', '/')
    application?.stop()
    document.body.innerHTML = ''
    delete window.Turbo
    delete Element.prototype.animate
    jest.restoreAllMocks()
    jest.clearAllTimers()
    jest.useRealTimers()
    controller = null
  })

  test.each([true, false])('snooze expiry follows the server visibility (%s) without navigation', async (visible) => {
    const item = mission('m1')
    await mount({ items: [item], top: item.key })
    csrfFetch.mockResolvedValueOnce({ ok: true, headers: new Headers({
      'X-Notice-Snoozed-Until': new Date(Date.now() + 86400000).toISOString(),
    }) })
    await controller.dismissTop()
    await replacePayload([item])
    await flush()
    expect(controller.queue).toEqual([])
    expect(zone.dataset.noticeBarRefreshAtValue).toBeTruthy()
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: visible ? [item] : [], refresh_at: null }) })
    await flush(21600000)
    expect(controller.queue).toEqual(visible ? [item] : [])
    expect(postedUrls()).toContain('/user_notices')
    expect(controller.removed.has(item.key)).toBe(!visible)
  })

  test('an early boundary refresh keeps an unexpired snooze hidden across snapshot restoration', async () => {
    const item = mission('m1')
    const announcement = notice('scheduled')
    await mount({ items: [item], top: item.key })
    const deadline = new Date(Date.now() + 86400000).toISOString()
    csrfFetch.mockResolvedValueOnce({ ok: true, headers: new Headers({ 'X-Notice-Snoozed-Until': deadline }) })
    await controller.dismissTop()
    controller.scheduleRefresh(new Date(Date.now() + 1000).toISOString())
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [announcement], refresh_at: deadline }) })
    await jest.advanceTimersByTimeAsync(1000)
    await controller.work
    expect(controller.queue).toEqual([announcement])
    expect(controller.removed.has(item.key)).toBe(true)
    expect(controller.snoozed.has(item.key)).toBe(true)

    document.dispatchEvent(new Event('turbo:before-cache'))
    const snapshot = zone.cloneNode(true)
    expect(JSON.parse(snapshot.querySelector('[data-notice-bar-target="payload"]').dataset.items)).toEqual([])
    application.stop()
    zone.remove()
    document.body.appendChild(snapshot)
    application = Application.start()
    application.register('notice-bar', NoticeBarController)
    await jest.advanceTimersByTimeAsync(0)
    zone = snapshot
    controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
    await flush()
    expect(controller.queue).toEqual([])
    expect(strip()).toBeNull()

    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [item, announcement], refresh_at: null }) })
    await jest.advanceTimersByTimeAsync(Date.parse(deadline) - Date.now())
    await controller.work
    expect(controller.queue).toEqual([item, announcement])
    expect(strip().dataset.key).toBe(item.key)
  })

  test.each(['dismiss', 'snooze', 'restore', 'complete'])('a %s broadcast supersedes an in-flight refresh', async (action) => {
    const item = notice('n1')
    await mount({ items: action === 'restore' ? [] : [item], top: item.key })
    let resolve
    csrfFetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
    const request = controller.feedRefresh.refresh()
    const current = action === 'restore' ? [item] : []
    const deadline = action === 'snooze' ? new Date(Date.now() + 86400000).toISOString() : ''
    const payload = payloadEl(current)
    payload.dataset.changed = item.key
    payload.dataset.refreshAt = deadline
    controller.payloadTarget.replaceWith(payload)
    await flush()
    resolve({ ok: true, json: async () => ({
      items: action === 'restore' ? [] : [item], refresh_at: new Date(Date.now() + 2000).toISOString(),
    }) })
    await request
    await flush()
    expect(controller.queue).toEqual(current)
    expect(controller.feedRefresh.deadline || null).toBe(deadline ? Date.parse(deadline) : null)
  })

  test('an automatic completion preserves the next deadline when it supersedes a refresh', async () => {
    const item = mission('m1')
    await mount({ items: [item], top: item.key })
    let resolve
    csrfFetch.mockReturnValueOnce(new Promise((done) => { resolve = done }))
    controller.scheduleRefresh(new Date(Date.now() + 1000).toISOString())
    await jest.advanceTimersByTimeAsync(1000)
    expect(csrfFetch).toHaveBeenCalledTimes(1)
    expect(controller.feedRefresh.deadline).toBeNull()
    const deadline = new Date(Date.now() + 86400000).toISOString()
    const payload = payloadEl([], { key: item.key, next_key: null })
    payload.dataset.refreshAt = deadline
    controller.payloadTarget.replaceWith(payload)
    await flush(1500)
    resolve({ ok: true, json: async () => ({ items: [item], refresh_at: null }) })
    await flush(1500)
    expect(controller.queue).toEqual([])
    expect(controller.feedRefresh.deadline).toBe(Date.parse(deadline))
    expect(controller.refreshAtValue).toBe(deadline)
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [notice('scheduled')], refresh_at: null }) })
    await jest.advanceTimersByTimeAsync(86400000)
    await flush(1500)
    expect(csrfFetch).toHaveBeenCalledTimes(2)
    expect(controller.queue).toEqual([notice('scheduled')])
  })

  test('a queued refresh is discarded when a payload arrives before the animation ends', async () => {
    const item = mission('m1')
    await mount({ items: [item], top: item.key })
    let finishAnimation
    controller.run(() => new Promise((done) => { finishAnimation = done }))
    await Promise.resolve()
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [item], refresh_at: null }) })
    const request = controller.feedRefresh.refresh()
    await jest.advanceTimersByTimeAsync(0)
    const reconcile = jest.spyOn(controller, 'reconcile')
    await replacePayload([])
    finishAnimation()
    await request
    await flush()
    expect(reconcile).toHaveBeenCalledTimes(1)
    expect(reconcile).toHaveBeenCalledWith([], null)
    expect(controller.queue).toEqual([])
  })

  test('a restored snapshot restarts its persisted snooze timer', async () => {
    const item = mission('m1')
    await mount({ items: [item], top: item.key })
    csrfFetch.mockResolvedValueOnce({ ok: true, headers: new Headers({
      'X-Notice-Snoozed-Until': new Date(Date.now() + 86400000).toISOString(),
    }) })
    await controller.dismissTop()
    document.dispatchEvent(new Event('turbo:before-cache'))
    const snapshot = zone.cloneNode(true)
    application.stop()
    zone.remove()
    document.body.appendChild(snapshot)
    application = Application.start()
    application.register('notice-bar', NoticeBarController)
    await jest.advanceTimersByTimeAsync(0)
    zone = snapshot
    controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [item] }) })
    await flush(21600000)
    expect(controller.queue).toEqual([item])
  })

  test('a mutation from another tab removes the notice and schedules snooze expiry', async () => {
    window.Turbo.cache = { clear: jest.fn() }
    const item = mission('remote')
    await mount({ items: [item], top: item.key })
    const deadline = new Date(Date.now() + 5000).toISOString()
    const payload = payloadEl([])
    payload.dataset.changed = item.key
    payload.dataset.refreshAt = deadline
    controller.payloadTarget.replaceWith(payload)
    await flush()
    expect(controller.queue).toEqual([])
    expect(controller.refreshAtValue).toBe(deadline)
    expect(window.Turbo.cache.clear).toHaveBeenCalled()
    csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ items: [item], refresh_at: null }) })
    await jest.advanceTimersByTimeAsync(5000)
    await flush()
    expect(controller.queue).toEqual([item])
  })

  test('replay broadcasts restore all reset missions without clearing unrelated removals', async () => {
    const item = mission('first')
    await mount({ items: [] })
    const c = controller
    for (const key of ['first', 'second', 'other']) {
      c.removed.add(key)
      c.snoozed.add(key)
    }
    const payload = document.createElement('div')
    payload.dataset.items = JSON.stringify([item])
    payload.dataset.changed = JSON.stringify(['first', 'second'])
    c.payloadTargetConnected(payload)
    await flush()
    expect(c.queue.map(item => item.key)).toEqual(['first'])
    expect([...c.removed]).toEqual(['other'])
    expect([...c.snoozed]).toEqual(['other'])
  })

  test('a restore broadcast clears the local removal for only the changed notice', async () => {
    const item = mission('remote')
    await mount({ items: [item], top: item.key })
    await controller.run(() => controller.dismissTop())
    controller.removed.add('other')
    const payload = payloadEl([item, notice('other')])
    payload.dataset.changed = item.key
    controller.payloadTarget.replaceWith(payload)
    await flush()
    expect(controller.queue).toEqual([item])
    expect(controller.removed.has(item.key)).toBe(false)
    expect(controller.snoozed.has(item.key)).toBe(false)
    expect(controller.removed.has('other')).toBe(true)
  })

  test.each(['complete', 'dismiss', 'snooze'])('%s stays removed after a Turbo snapshot restoration', async (action) => {
    const item = action === 'snooze' ? mission('m1') : notice('n1')
    await mount({ items: [item, notice('remaining')], top: item.key })
    const operation = action === 'complete' ? controller.followCta(item) : controller.dismissTop()
    await flush()
    await operation
    document.dispatchEvent(new Event('turbo:before-cache'))
    const snapshot = zone.cloneNode(true)
    application.stop()
    zone.remove()
    document.body.appendChild(snapshot)
    application = Application.start()
    application.register('notice-bar', NoticeBarController)
    await jest.advanceTimersByTimeAsync(0)
    zone = snapshot
    controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
    await flush(400)
    expect(controller.queue.map(({ key }) => key)).toEqual(['remaining'])
  })

  test.each(['complete', 'dismiss', 'snooze'])('%s invalidates older A snapshots across A → B → C → A', async (action) => {
    const item = action === 'snooze' ? mission('m1') : notice('n1')
    const snapshots = new Map()
    window.Turbo.cache = { clear: jest.fn(() => snapshots.clear()) }
    await mount({ items: [item], top: item.key })
    document.dispatchEvent(new Event('turbo:before-cache'))
    snapshots.set('A', zone.cloneNode(true))
    application.stop()
    zone.remove()
    await mount({ items: [item], top: item.key }) // B receives the same server feed.
    const operation = action === 'complete' ? controller.followCta(item) : controller.dismissTop()
    await flush()
    await operation
    document.dispatchEvent(new Event('turbo:before-cache'))
    snapshots.set('B', zone.cloneNode(true))
    application.stop()
    zone.remove()
    await mount({ items: [] }) // C receives the updated server feed.
    expect(window.Turbo.cache.clear).toHaveBeenCalledTimes(1)
    expect(snapshots.has('A')).toBe(false) // Turbo must fetch A again on restoration.
    application.stop()
    zone.remove()
    await mount({ items: [], top: item.key })
    expect(strip()).toBeNull()
  })

  test('a refused state change does not invalidate snapshots', async () => {
    window.Turbo.cache = { clear: jest.fn() }
    csrfFetch.mockResolvedValue({ ok: false })
    await mount()
    expect(await controller.post('n1', 'complete')).toBe(false)
    expect(window.Turbo.cache.clear).not.toHaveBeenCalled()
  })

  test('undo remains present in a Turbo snapshot', async () => {
    const item = mission('m1')
    await mount({ items: [item], top: item.key })
    const dismissal = controller.dismissTop()
    await flush()
    await dismissal
    const restoration = controller.restore(item)
    await flush()
    await restoration
    document.dispatchEvent(new Event('turbo:before-cache'))
    expect(JSON.parse(controller.payloadTarget.dataset.items)).toEqual([item])
  })

  test.each(['?tab=agents', '#agents', '?open_comments=true'])('navigates to a different URL state: %s', async (suffix) => {
    const url = window.location.pathname + suffix
    await mount({ items: [mission('m1', { cta_url: url })], top: 'm1' })
    controller.startMission(controller.queue[0])
    expect(window.Turbo.visit).toHaveBeenCalledWith(url)
    expect(sessionStorage.getItem(PENDING_KEY)).toBe('m1')
  })

  describe('first render', () => {
    test('drops in a notice that is new to this tab after a short delay', async () => {
      sessionStorage.setItem(TOP_KEY, 'other')
      zone = null
      const items = [mission('m1'), notice('n1'), notice('n2'), notice('n3')]
      // Mount without flushing the drop delay.
      zone = document.createElement('div')
      zone.setAttribute('data-controller', 'notice-bar')
      zone.setAttribute('data-notice-bar-feed-url-value', '/user_notices')
    zone.setAttribute('data-notice-bar-url-value', '/user_notices/__key__')
      zone.setAttribute('data-notice-bar-i18n-value', JSON.stringify(I18N))
      zone.innerHTML = '<div data-notice-bar-target="stack"></div><div data-notice-bar-target="toasts"></div>'
      zone.appendChild(payloadEl(items))
      document.body.appendChild(zone)
      application = Application.start()
      application.register('notice-bar', NoticeBarController)
      await jest.advanceTimersByTimeAsync(0)
      controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
      expect(zone.querySelector('.notice-strip')).toBeNull()
      expect(controller.busy).toBe(true)

      await flush(300)
      const top = zone.querySelector('.notice-strip')
      expect(top.dataset.key).toBe('m1')
      expect(top.querySelector('.notice-strip__count').textContent).toBe('+3')
      expect(zone.querySelectorAll('.notice-peek')).toHaveLength(2)
      expect(zone.querySelector('[data-notice-bar-target="stack"]').style.paddingBottom).toBe('10px')
      expect(sessionStorage.getItem(TOP_KEY)).toBe('m1')
    })

    test('renders immediately when the top notice was already shown in this tab', async () => {
      sessionStorage.setItem(TOP_KEY, 'n1')
      zone = document.createElement('div')
      zone.setAttribute('data-controller', 'notice-bar')
      zone.setAttribute('data-notice-bar-feed-url-value', '/user_notices')
    zone.setAttribute('data-notice-bar-url-value', '/user_notices/__key__')
      zone.setAttribute('data-notice-bar-i18n-value', JSON.stringify(I18N))
      zone.innerHTML = '<div data-notice-bar-target="stack"></div><div data-notice-bar-target="toasts"></div>'
      zone.appendChild(payloadEl([notice('n1')]))
      document.body.appendChild(zone)
      application = Application.start()
      application.register('notice-bar', NoticeBarController)
      await jest.advanceTimersByTimeAsync(0)
      controller = application.getControllerForElementAndIdentifier(zone, 'notice-bar')
      await controller.work
      expect(zone.querySelector('.notice-strip').dataset.key).toBe('n1')
      expect(zone.querySelector('.notice-strip__count')).toBeNull()
    })

    test('renders nothing for an empty or malformed payload', async () => {
      await mount({ items: 'not json' })
      expect(stack().children).toHaveLength(0)
      expect(stack().style.paddingBottom).toBe('0px')
    })

    test('treats a payload without data-items as empty', async () => {
      await mount({ items: undefined })
      expect(stack().children).toHaveLength(0)
    })

    test('animates the stack height when it changes', async () => {
      Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
      jest.spyOn(HTMLElement.prototype, 'offsetHeight', 'get').mockImplementation(function () {
        return this.childElementCount * 10
      })
      await mount({ items: [notice('n1')], top: 'n1' })
      const stackCalls = Element.prototype.animate.mock.contexts.filter((el) => el === stack())
      expect(stackCalls).toHaveLength(1)
      expect(Element.prototype.animate.mock.calls[0][0]).toEqual([{ height: '0px' }, { height: '10px' }])
    })

    test('tolerates disabled session storage', async () => {
      jest.spyOn(Storage.prototype, 'getItem').mockImplementation(() => { throw new Error('denied') })
      jest.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new Error('denied') })
      await mount({ items: [notice('n1')] })
      expect(strip().dataset.key).toBe('n1')
    })
  })

  describe('detail sheet', () => {
    test('clicking the strip opens a dialog with the notice detail', async () => {
      await mount({ items: [mission('m1')], top: 'm1' })
      await openSheet()
      const dialog = document.querySelector('[role="dialog"]')
      expect(dialog.hidden).toBe(false)
      expect(dialog.querySelector('#notice-sheet-title').textContent).toBe('Mission m1')
      expect(dialog.querySelectorAll('.notice-sheet__steps li')).toHaveLength(2)
      expect(strip().style.visibility).toBe('hidden')
    })

    test('closes via the × button', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__close').click()
      await flush()
      expect(sheetEl().hidden).toBe(true)
      expect(strip().style.visibility).toBe('')
      expect(csrfFetch).not.toHaveBeenCalled()
    })

    test('closes via the backdrop', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      await openSheet()
      document.querySelector('.notice-backdrop').click()
      await flush()
      expect(sheetEl().hidden).toBe(true)
    })

    test('closes via Escape and ignores other keys', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      await openSheet()
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', bubbles: true }))
      await flush()
      expect(sheetEl().hidden).toBe(false)
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      await flush()
      expect(sheetEl().hidden).toBe(true)
    })

    test('Escape with no sheet and no spotlight is a no-op', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      expect(() => document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))).not.toThrow()
    })

    test('Enter or Space on the strip opens the sheet; other keys and targets are ignored', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      strip().dispatchEvent(new KeyboardEvent('keydown', { key: 'x', bubbles: true }))
      strip().querySelector('.notice-strip__close').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
      await flush()
      expect(sheetEl()).toBeNull()

      const event = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })
      strip().dispatchEvent(event)
      await flush()
      expect(event.defaultPrevented).toBe(true)
      expect(sheetEl().hidden).toBe(false)

      sheetEl().querySelector('.notice-sheet__close').click()
      await flush()
      strip().dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true }))
      await flush()
      expect(sheetEl().hidden).toBe(false)
    })

    test('clicks on the stack outside the strip do nothing', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      stack().click()
      await flush()
      expect(sheetEl()).toBeNull()
    })

    test('openDetail and closeDetail are no-ops without a notice or an open sheet', async () => {
      await mount({ items: [], top: 'x' })
      await controller.openDetail()
      await controller.closeDetail()
      await controller.dismissTop()
      await controller.renderStack()
      expect(sheetEl()).toBeNull()
      expect(stack().children).toHaveLength(0)
    })
  })

  describe('dismissing', () => {
    test('"later" on a mission snoozes it and offers undo that restores it', async () => {
      await mount({ items: [mission('m1'), notice('n1')], top: 'm1' })
      await openSheet()
      expect(sheetEl().querySelector('.notice-sheet__later').textContent).toBe('Later')
      sheetEl().querySelector('.notice-sheet__later').click()
      await flush()
      expect(sheetEl().hidden).toBe(true)
      expect(postedUrls()).toEqual(['/user_notices/m1/snooze'])
      expect(csrfFetch).toHaveBeenCalledWith('/user_notices/m1/snooze', { method: 'POST', headers: { Accept: 'application/json' } })
      expect(strip().dataset.key).toBe('n1')
      expect(toastText()).toContain('Snoozed')

      // A payload replay must not bring the snoozed mission back.
      await replacePayload([mission('m1'), notice('n1')])
      await flush()
      expect(strip().dataset.key).toBe('n1')

      zone.querySelector('.notice-toast__action').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/m1/snooze', '/user_notices/m1/restore'])
      expect(strip().dataset.key).toBe('m1')
    })

    test('snooze waits for persistence before removing the mission and offering undo', async () => {
      let finishSnooze
      csrfFetch.mockImplementationOnce(() => new Promise((resolve) => { finishSnooze = resolve }))
      await mount({ items: [mission('m1'), notice('n1')], top: 'm1' })
      strip().querySelector('.notice-strip__close').click()
      await jest.advanceTimersByTimeAsync(0)
      expect(postedUrls()).toEqual(['/user_notices/m1/snooze'])
      expect(strip().dataset.key).toBe('m1')
      expect(zone.querySelector('.notice-toast__action')).toBeNull()
      document.dispatchEvent(new Event('turbo:before-cache'))
      expect(JSON.parse(controller.payloadTarget.dataset.items).map(({ key }) => key)).toEqual(['m1', 'n1'])

      finishSnooze({ ok: true })
      await flush()
      zone.querySelector('.notice-toast__action').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/m1/snooze', '/user_notices/m1/restore'])
      expect(strip().dataset.key).toBe('m1')
    })

    test.each(['dismiss', 'snooze'].flatMap((action) => ['rejected', 'offline'].map((failure) => [action, failure])))('%s retains the notice after %s and allows retry', async (action, failure) => {
      const item = action === 'snooze' ? mission('m1') : notice('n1')
      await mount({ items: [item], top: item.key })
      if (failure === 'offline') csrfFetch.mockRejectedValueOnce(new Error('offline'))
      else csrfFetch.mockResolvedValueOnce({ ok: false })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(controller.removed.has(item.key)).toBe(false)
      expect(strip().dataset.key).toBe(item.key)
      expect(zone.querySelector('.notice-toast__action')).toBeNull()
      document.dispatchEvent(new Event('turbo:before-cache'))
      expect(JSON.parse(controller.payloadTarget.dataset.items)).toEqual([item])
      await replacePayload([item])
      await flush()
      expect(strip().dataset.key).toBe(item.key)
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(strip()).toBeNull()
    })

    test('a refused restore keeps the mission hidden', async () => {
      await mount({ items: [mission('m1'), notice('n1')], top: 'm1' })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      csrfFetch.mockResolvedValueOnce({ ok: false })
      zone.querySelector('.notice-toast__action').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/m1/snooze', '/user_notices/m1/restore'])
      expect(strip().dataset.key).toBe('n1')

      // Still filtered from replays: the server kept it snoozed or completed it.
      await replacePayload([mission('m1'), notice('n1')])
      await flush()
      expect(strip().dataset.key).toBe('n1')
    })

    test('× on a non-mission dismisses it without a toast', async () => {
      await mount({ items: [notice('n1'), notice('n2')], top: 'n1' })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/n1/dismiss'])
      expect(strip().dataset.key).toBe('n2')
      expect(sheetEl()).toBeNull()
      expect(zone.querySelector('.notice-toast')).toBeNull()
    })

    test('× on the last notice empties the bar', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(stack().children).toHaveLength(0)
    })

    test('logs failed requests', async () => {
      csrfFetch.mockRejectedValue(new Error('offline'))
      await mount({ items: [notice('n1')], top: 'n1' })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(console.error).toHaveBeenCalledWith('[notice-bar]', 'dismiss', expect.any(Error))
    })

    test('encodes the key in the URL', async () => {
      await mount({ items: [notice('a/b')], top: 'a/b' })
      strip().querySelector('.notice-strip__close').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/a%2Fb/dismiss'])
    })
  })

  describe('CTA', () => {
    test('on a non-mission completes it and visits its URL with Turbo', async () => {
      await mount({ items: [notice('n1'), notice('n2')], top: 'n1' })
      await openSheet()
      expect(sheetEl().querySelector('.notice-sheet__later').textContent).toBe('Close')
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/n1/complete'])
      expect(strip().dataset.key).toBe('n2')
      expect(window.Turbo.visit).toHaveBeenCalledWith('/news')
    })

    test.each([true, false])('waits for completion before navigating (Turbo: %s)', async (turbo) => {
      let finishCompletion
      csrfFetch.mockImplementationOnce(() => new Promise((resolve) => { finishCompletion = resolve }))
      if (!turbo) delete window.Turbo
      await mount({ items: [notice('n1', { cta_url: '#news' }), notice('n2')], top: 'n1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await jest.advanceTimersByTimeAsync(1000)
      expect(postedUrls()).toEqual(['/user_notices/n1/complete'])
      expect(strip().dataset.key).toBe('n1')
      expect(controller.removed.has('n1')).toBe(false)
      if (turbo) expect(window.Turbo.visit).not.toHaveBeenCalled()
      else expect(window.location.hash).toBe('')

      finishCompletion({ ok: true })
      await flush()
      expect(strip().dataset.key).toBe('n2')
      if (turbo) expect(window.Turbo.visit).toHaveBeenCalledWith('#news')
      else expect(window.location.hash).toBe('#news')
      window.location.hash = ''
    })

    test.each(['refused', 'offline'])('keeps the notice available when completion is %s', async (failure) => {
      if (failure === 'refused') csrfFetch.mockResolvedValueOnce({ ok: false })
      else csrfFetch.mockRejectedValueOnce(new Error('offline'))
      await mount({ items: [notice('n1'), notice('n2')], top: 'n1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(strip().dataset.key).toBe('n1')
      expect(controller.removed.has('n1')).toBe(false)
      expect(window.Turbo.visit).not.toHaveBeenCalled()

      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(strip().dataset.key).toBe('n2')
      expect(window.Turbo.visit).toHaveBeenCalledWith('/news')
    })

    test('on a non-mission without a URL only completes it', async () => {
      await mount({ items: [notice('n1', { cta_url: null })], top: 'n1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/n1/complete'])
      expect(window.Turbo.visit).not.toHaveBeenCalled()
      expect(stack().children).toHaveLength(0)
    })

    test('falls back to location.assign without Turbo', async () => {
      delete window.Turbo
      await mount({ items: [notice('n1', { cta_url: '#news' })], top: 'n1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(window.location.hash).toBe('#news')
      window.location.hash = ''
    })

    test('on a mission with its target present spotlights it', async () => {
      const target = makeVisible(document.createElement('textarea'))
      target.id = 'target'
      document.body.appendChild(target)
      await mount({ items: [mission('m1')], top: 'm1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(target.classList.contains('notice-spot')).toBe(true)
      expect(document.querySelector('.notice-spot-tip').textContent).toBe('Type here')
      expect(csrfFetch).not.toHaveBeenCalled()
      expect(strip().dataset.key).toBe('m1')

      // Escape without an open sheet clears the spotlight.
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
      expect(target.classList.contains('notice-spot')).toBe(false)
      expect(document.querySelector('.notice-spot-tip')).toBeNull()
    })

    test.each([
      '/creatives/99?open_comments=true&topic_id=20',
      '/creatives/42?open_comments=true&topic_id=21',
      '/creatives/42?open_comments=true&topic_id=20',
    ])('opens the specified Inbox topic even with a visible composer at %s', async (currentUrl) => {
      window.history.replaceState({}, '', currentUrl)
      const target = makeVisible(document.createElement('textarea'))
      target.setAttribute('data-comments--form-target', 'textarea')
      document.body.appendChild(target)
      const url = '/creatives/42?open_comments=true&topic_id=20'
      const item = mission('onboarding_call_agent', {
        cta_url: url, target: "[data-comments--form-target='textarea']",
      })
      await mount({ items: [item], top: item.key })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(window.Turbo.visit).toHaveBeenCalledWith(url)
      expect(sessionStorage.getItem(PENDING_KEY)).toBe(item.key)
      expect(target.classList.contains('notice-spot')).toBe(false)
      expect(csrfFetch).not.toHaveBeenCalled()
    })

    test('on a mission whose target lives on another page remembers the spotlight and visits', async () => {
      await mount({ items: [mission('m1')], top: 'm1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(sessionStorage.getItem(PENDING_KEY)).toBe('m1')
      expect(window.Turbo.visit).toHaveBeenCalledWith('/elsewhere')
    })

    test('opens hidden chat even when the mission destination is the current page', async () => {
      const target = document.createElement('textarea')
      target.id = 'target'
      target.style.display = 'none'
      document.body.appendChild(target)
      const url = `${window.location.pathname}?open_comments=true`
      await mount({ items: [mission('m1', { cta_url: url })], top: 'm1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(window.Turbo.visit).toHaveBeenCalledWith(url)
      expect(sessionStorage.getItem(PENDING_KEY)).toBe('m1')
      expect(target.classList.contains('notice-spot')).toBe(false)
    })

    test('on a mission whose target is missing on this page shows a toast', async () => {
      await mount({ items: [mission('m1', { cta_url: window.location.pathname })], top: 'm1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(toastText()).toBe('Target missing')
      expect(window.Turbo.visit).not.toHaveBeenCalled()
      expect(sessionStorage.getItem(PENDING_KEY)).toBeNull()
    })

    test('on a mission without a URL and target shows a toast', async () => {
      await mount({ items: [mission('m1', { cta_url: null, target: null })], top: 'm1' })
      await openSheet()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(toastText()).toBe('Target missing')
    })
  })

  describe('resuming a spotlight after a visit', () => {
    test('retries until the target renders', async () => {
      sessionStorage.setItem(PENDING_KEY, 'm1')
      await mount({ items: [mission('m1')], top: 'm1' })
      expect(sessionStorage.getItem(PENDING_KEY)).toBeNull()
      const target = makeVisible(document.createElement('div'))
      target.id = 'target'
      document.body.appendChild(target)
      await jest.advanceTimersByTimeAsync(300)
      expect(target.classList.contains('notice-spot')).toBe(true)
    })

    test('gives up after the retries run out', async () => {
      sessionStorage.setItem(PENDING_KEY, 'm1')
      await mount({ items: [mission('m1')], top: 'm1' })
      await jest.advanceTimersByTimeAsync(3000)
      const target = makeVisible(document.createElement('div'))
      target.id = 'target'
      document.body.appendChild(target)
      await jest.advanceTimersByTimeAsync(600)
      expect(target.classList.contains('notice-spot')).toBe(false)
    })

    test('ignores a pending key for a notice that is not in the list', async () => {
      sessionStorage.setItem(PENDING_KEY, 'gone')
      const target = makeVisible(document.createElement('div'))
      target.id = 'target'
      document.body.appendChild(target)
      await mount({ items: [mission('m1')], top: 'm1' })
      expect(target.classList.contains('notice-spot')).toBe(false)
    })
  })

  describe('server updates', () => {
    test('completion of the top mission celebrates then flips to the next one', async () => {
      await mount({ items: [mission('m1'), mission('m2')], top: 'm1' })
      await replacePayload([mission('m2')], { key: 'm1', done: 'First mission done', next_key: 'm2' })
      await jest.advanceTimersByTimeAsync(0)
      expect(strip().dataset.key).toBe('m1')
      expect(strip().querySelector('.notice-strip__tag').textContent).toBe('Done')
      expect(strip().querySelector('.notice-strip__title').textContent).toBe('First mission done')
      expect(strip().querySelector('.notice-strip__summary').textContent).toBe('Next: Mission m2')
      expect(strip().querySelector('.notice-strip__check')).not.toBeNull()
      expect(strip().querySelector('.notice-strip__close').style.visibility).toBe('hidden')
      expect(document.querySelectorAll('.notice-confetti')).toHaveLength(0)

      await flush(1500)
      expect(strip().dataset.key).toBe('m2')
      expect(zone.querySelector('.notice-toast')).toBeNull()
    })

    test('completion of the last mission celebrates with confetti and clears the bar', async () => {
      // Keep confetti pieces alive so they can be observed; everything else finishes at once.
      Element.prototype.animate = jest.fn(function () {
        return { finished: this.classList.contains('notice-confetti') ? new Promise(() => {}) : Promise.resolve() }
      })
      await mount({ items: [mission('m1')], top: 'm1' })
      await replacePayload([], { key: 'm1', done: 'All missions done', next_key: null })
      await jest.advanceTimersByTimeAsync(0)
      expect(strip().querySelector('.notice-strip__summary').textContent).toBe('All done')
      expect(document.querySelectorAll('.notice-confetti').length).toBeGreaterThan(0)
      await flush(1500)
      expect(stack().children).toHaveLength(0)
    })

    test('completion whose next mission is not on top exits and rises to the new top', async () => {
      await mount({ items: [mission('m1'), notice('n1')], top: 'm1' })
      await replacePayload([notice('n1'), mission('m2')], { key: 'm1', done: 'Done', next_key: 'm2' })
      await flush(1500)
      expect(strip().dataset.key).toBe('n1')
    })

    test('completion of a mission that is not on top shows a toast', async () => {
      await mount({ items: [notice('n1'), mission('m1')], top: 'n1' })
      await replacePayload([notice('n1'), mission('m2')], { key: 'm1', done: 'Done', next_key: 'm2' })
      await flush()
      expect(strip().dataset.key).toBe('n1')
      expect(toastText()).toBe('Mission done')

      await replacePayload([notice('n1')], { key: 'm2', done: 'Done', next_key: null })
      await flush()
      expect(toastText()).toBe('Group done')
    })

    test('completion clears an active spotlight', async () => {
      const target = makeVisible(document.createElement('div'))
      target.id = 'target'
      document.body.appendChild(target)
      await mount({ items: [notice('n1'), mission('m1')], top: 'n1' })
      controller.startMission(mission('m1'))
      expect(target.classList.contains('notice-spot')).toBe(true)
      await replacePayload([notice('n1')], { key: 'm1', done: 'Done', next_key: null })
      await flush()
      expect(target.classList.contains('notice-spot')).toBe(false)
    })

    test('a new top notice drops in; a longer list with the same top bumps the count', async () => {
      Element.prototype.animate = jest.fn(() => ({ finished: Promise.resolve() }))
      await mount({ items: [notice('n1')], top: 'n1' })
      await replacePayload([notice('n0'), notice('n1')])
      await flush()
      expect(strip().dataset.key).toBe('n0')
      expect(strip().querySelector('.notice-strip__count').textContent).toBe('+1')

      Element.prototype.animate.mockClear()
      await replacePayload([notice('n0'), notice('n1'), notice('n2')])
      await flush()
      expect(strip().querySelector('.notice-strip__count').textContent).toBe('+2')
      const animated = Element.prototype.animate.mock.contexts
      expect(animated).toContain(zone.querySelector('.notice-strip__count'))
      expect(animated).toContain(zone.querySelector('.notice-peek--1'))

      Element.prototype.animate.mockClear()
      await replacePayload([notice('n0')])
      await flush()
      expect(strip().querySelector('.notice-strip__count')).toBeNull()
      expect(Element.prototype.animate.mock.contexts).not.toContain(strip())
    })

    test('a payload arriving while the sheet is open is applied after it closes', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      await openSheet()
      await replacePayload([notice('n0'), notice('n1')])
      await flush()
      expect(strip().dataset.key).toBe('n1')
      expect(controller.deferred).toHaveLength(1)

      sheetEl().querySelector('.notice-sheet__close').click()
      await flush()
      expect(controller.deferred).toEqual([])
      expect(strip().dataset.key).toBe('n0')
    })

    test('every completion deferred behind the sheet is celebrated in order', async () => {
      await mount({ items: [mission('m1')], top: 'm1' })
      await openSheet()
      const celebrate = jest.spyOn(controller, 'celebrate')
      await replacePayload([mission('m1'), notice('n8')])
      await replacePayload([mission('m2')], { key: 'm1', done: 'First done', next_key: 'm2' })
      await replacePayload([mission('m2'), notice('n8')])
      await replacePayload([mission('m2'), notice('n8'), notice('n9')])
      await replacePayload([notice('n8'), notice('n9')], { key: 'm2', done: 'Second done', next_key: null })
      await flush()
      expect(controller.deferred.map(([, done]) => done?.key)).toEqual(['m1', undefined, 'm2'])

      sheetEl().querySelector('.notice-sheet__close').click()
      await flush(4000)
      expect(celebrate.mock.calls.map(([, done]) => done.key)).toEqual(['m1', 'm2'])
      expect(controller.deferred).toEqual([])
    })

    test('a deferred payload lands after the CTA acted on the notice the user saw', async () => {
      await mount({ items: [notice('n1'), notice('n2')], top: 'n1' })
      await openSheet()
      await replacePayload([notice('n1'), notice('n2'), notice('n3')])
      await flush()
      sheetEl().querySelector('.notice-sheet__cta').click()
      await flush()
      expect(postedUrls()).toEqual(['/user_notices/n1/complete'])
      expect(strip().dataset.key).toBe('n2')
      expect(strip().querySelector('.notice-strip__count').textContent).toBe('+1')
    })
  })

  describe('flash and lifecycle', () => {
    test('adopts the server-rendered flash as a self-dismissing toast', async () => {
      await mount({ items: [], flash: 'Saved' })
      const flash = zone.querySelector('[data-notice-bar-target="flash"]')
      expect(flash.querySelector('.notice-toast__timer')).not.toBeNull()
      await jest.advanceTimersByTimeAsync(4000)
      expect(flash.isConnected).toBe(false)
    })

    test('before-cache removes transient UI before the document is cloned', async () => {
      const target = makeVisible(document.createElement('textarea'))
      target.id = 'target'
      document.body.appendChild(target)
      await mount({ items: [mission('m1')], top: 'm1', flash: 'Hi' })
      await openSheet()
      controller.startMission(mission('m1'))
      expect(strip().style.visibility).toBe('hidden')
      document.dispatchEvent(new Event('turbo:before-cache'))
      const snapshot = document.body.cloneNode(true)
      expect(snapshot.querySelector('.notice-sheet, .notice-backdrop, .notice-spot-tip, .notice-spot, .notice-toast')).toBeNull()
      expect(snapshot.querySelector('.notice-strip').style.visibility).toBe('')
      expect(jest.getTimerCount()).toBe(0)
      // Cleanup is repeatable and collaborators can be recreated if navigation stops.
      document.dispatchEvent(new Event('turbo:before-cache'))
      await openSheet()
      expect(document.querySelectorAll('.notice-sheet')).toHaveLength(1)
    })

    test('disconnect tears down the sheet, toasts and spotlight', async () => {
      const target = makeVisible(document.createElement('div'))
      target.id = 'target'
      document.body.appendChild(target)
      await mount({ items: [mission('m1')], top: 'm1', flash: 'Hi' })
      await openSheet()
      controller.startMission(mission('m1'))
      zone.remove()
      await jest.advanceTimersByTimeAsync(0)
      expect(document.querySelector('.notice-sheet')).toBeNull()
      expect(document.querySelector('.notice-backdrop')).toBeNull()
      expect(target.classList.contains('notice-spot')).toBe(false)
      expect(controller.sheetView).toBeNull()
      expect(jest.getTimerCount()).toBe(0)
    })

    test('disconnect without any collaborators is safe', async () => {
      await mount({ items: null })
      zone.remove()
      await jest.advanceTimersByTimeAsync(0)
      expect(controller.toastLayer).toBeNull()
    })
  })

  describe('serialized work', () => {
    test('user input is ignored while work is running', async () => {
      sessionStorage.setItem(TOP_KEY, 'n1')
      await mount({ items: [notice('n1')], top: 'n1' })
      let release
      const job = jest.fn(() => new Promise((resolve) => { release = resolve }))
      controller.run(job)
      await jest.advanceTimersByTimeAsync(0)
      expect(controller.busy).toBe(true)

      const ignored = jest.fn()
      expect(controller.act(ignored)).toBeUndefined()
      strip().click()
      strip().querySelector('.notice-strip__close').click()
      release()
      await flush()
      expect(ignored).not.toHaveBeenCalled()
      expect(sheetEl()).toBeNull()
      expect(csrfFetch).not.toHaveBeenCalled()
      expect(controller.busy).toBe(false)
    })

    test('a failing job is logged and does not block later work', async () => {
      await mount({ items: [notice('n1')], top: 'n1' })
      controller.run(() => { throw new Error('boom') })
      await flush()
      expect(console.error).toHaveBeenCalledWith('[notice-bar]', expect.any(Error))
      expect(controller.busy).toBe(false)
      await openSheet()
    })
  })
})
