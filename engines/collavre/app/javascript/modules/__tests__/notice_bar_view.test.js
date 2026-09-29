/**
 * @jest-environment jsdom
 */

import { h, kindClass, buildStrip, buildPeeks, buildSheet, buildToast, CHECK_SVG } from '../notice_bar/view'

const i18n = { more: 'More', dismiss: 'Dismiss', close: 'Close', later: 'Later', mission_hint: 'Stays until done' }
const item = { key: 'k1', kind: 'announcement', icon: 'i', tag: 'New', title: '<b>T</b>', summary: 'S', body: 'B', cta: 'Go' }

describe('notice bar view', () => {
  test('h creates elements with optional class and text', () => {
    expect(h('span').outerHTML).toBe('<span></span>')
    const el = h('p', 'x', '<b>')
    expect(el.className).toBe('x')
    expect(el.textContent).toBe('<b>')
    expect(el.innerHTML).toBe('&lt;b&gt;')
  })

  test('kindClass maps the kind', () => {
    expect(kindClass({ kind: 'mission' })).toBe('notice-kind-mission')
  })

  test('buildStrip renders an interactive strip with count and close button', () => {
    const strip = buildStrip(item, { i18n, extra: 2 })
    expect(strip.className).toBe('notice-strip notice-kind-announcement')
    expect(strip.dataset.key).toBe('k1')
    expect(strip.tabIndex).toBe(0)
    expect(strip.getAttribute('role')).toBe('button')
    expect(strip.querySelector('.notice-strip__title').textContent).toBe('<b>T</b>')
    expect(strip.querySelector('.notice-strip__more').textContent).toBe('More')
    expect(strip.querySelector('.notice-strip__count').textContent).toBe('+2')
    const close = strip.querySelector('.notice-strip__close')
    expect(close.type).toBe('button')
    expect(close.getAttribute('aria-label')).toBe('Dismiss')
  })

  test('buildStrip omits the count with no extras and controls when not interactive', () => {
    expect(buildStrip(item, { i18n }).querySelector('.notice-strip__count')).toBeNull()
    const plain = buildStrip(item, { i18n, extra: 3, interactive: false })
    expect(plain.getAttribute('role')).toBeNull()
    expect(plain.querySelector('.notice-strip__close')).toBeNull()
    expect(plain.querySelector('.notice-strip__count')).toBeNull()
  })

  test('buildPeeks renders at most two peeks', () => {
    const peeks = buildPeeks([{ kind: 'a' }, { kind: 'b' }, { kind: 'c' }])
    expect(peeks.map((p) => p.className)).toEqual(['notice-peek notice-peek--1 notice-kind-a', 'notice-peek notice-peek--2 notice-kind-b'])
    expect(buildPeeks([])).toEqual([])
  })

  test('buildSheet for a mission includes steps, hint and a later button', () => {
    const steps = [{ title: 'one', state: 'done' }, { title: 'two', state: 'current' }, { title: 'three', state: 'todo' }]
    const parts = buildSheet({ ...item, kind: 'mission', steps }, i18n)
    const lis = parts.content.querySelectorAll('.notice-sheet__steps li')
    expect(Array.from(lis).map((li) => li.className)).toEqual(['is-done', 'is-current', ''])
    expect(Array.from(lis).map((li) => li.textContent)).toEqual(['✓one', '2two', '3three'])
    expect(parts.content.querySelector('.notice-sheet__hint').textContent).toBe('Stays until done')
    expect(parts.later.textContent).toBe('Later')
    expect(parts.cta.textContent).toBe('Go')
    expect(parts.cta.className).toContain('notice-sheet__cta')
    expect(parts.close.getAttribute('aria-label')).toBe('Close')
    expect(parts.icon.className).toBe('notice-sheet__icon')
    expect(parts.ghost.querySelector('.notice-strip .notice-strip__close')).toBeNull()
    expect(parts.inner.querySelector('#notice-sheet-title').textContent).toBe('<b>T</b>')
  })

  test('buildSheet for a plain notice has no steps or hint and a close button', () => {
    const parts = buildSheet(item, i18n)
    expect(parts.content.querySelector('.notice-sheet__steps')).toBeNull()
    expect(parts.content.querySelector('.notice-sheet__hint')).toBeNull()
    expect(parts.later.textContent).toBe('Close')
    expect(parts.content.querySelector('p').textContent).toBe('B')
  })

  test('buildToast with and without an action', () => {
    const plain = buildToast('Hi')
    expect(plain.textContent).toBe('Hi')
    expect(plain.querySelector('button')).toBeNull()
    const withAction = buildToast('Snoozed', { label: 'Undo' })
    const button = withAction.querySelector('button.notice-toast__action')
    expect(button.textContent).toBe('Undo')
    expect(button.type).toBe('button')
  })

  test('CHECK_SVG contains the animated path', () => {
    expect(CHECK_SVG).toContain('notice-strip__check')
    expect(CHECK_SVG).toContain('<path')
  })
})
