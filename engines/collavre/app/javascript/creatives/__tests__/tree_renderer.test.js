/**
 * @jest-environment jsdom
 */
import { jest } from '@jest/globals'

import {
  applyRowProperties,
  replaceProgressControl,
  syncProgressHtmlFromDom,
  updateProgressHtml,
} from '../tree_renderer'

const TOGGLE_HTML = '<span class="progress-toggle-wrap" data-progress-toggle="true" data-current-progress="0" data-new-progress="1" data-mark-complete="Mark complete" data-mark-incomplete="Mark incomplete" title="Mark complete"><input type="checkbox" class="progress-toggle-checkbox" aria-label="Mark complete"></span>'

test('updates checkbox markup and the next action for binary progress broadcasts', () => {
  const complete = updateProgressHtml(TOGGLE_HTML, 1, '100%')
  expect(complete).toContain('checked="checked"')
  expect(complete).toContain('data-current-progress="1"')
  expect(complete).toContain('data-new-progress="0"')
  expect(complete).toContain('title="Mark incomplete"')
  expect(complete).toContain('aria-label="Mark incomplete"')

  const incomplete = updateProgressHtml(complete, 0, '0%')
  expect(incomplete).not.toContain('checked="checked"')
  expect(incomplete).toContain('data-current-progress="0"')
  expect(incomplete).toContain('data-new-progress="1"')
  expect(incomplete).toContain('title="Mark complete"')
  expect(incomplete).toContain('aria-label="Mark complete"')
})

test('keeps percentage markup working for non-interactive progress', () => {
  const html = '<span class="creative-progress-incomplete">0%</span>'

  expect(updateProgressHtml(html, 0.5, '50%')).toBe('<span class="creative-progress-incomplete">50%</span>')
  expect(updateProgressHtml(html, 1, '✓')).toBe('<span class="creative-progress-complete">✓</span>')
})

test('replaces only the progress control while preserving row-end content', () => {
  const html = '<div class="creative-row-end">' + TOGGLE_HTML + '<button class="comments-btn">Comments</button></div>'
  const rollup = '<span class="creative-progress-incomplete">50%</span>'

  const result = replaceProgressControl(html, rollup)

  expect(result).toContain(rollup)
  expect(result).not.toContain('progress-toggle-checkbox')
  expect(result).toContain('comments-btn')
})

test('keeps a broadcast progress template instead of restoring stale DOM markup', () => {
  const row = document.createElement('creative-tree-row')
  row.progressHtml = '<span class="creative-progress-incomplete">0%</span>'
  row.dataset.progressHtml = row.progressHtml
  row.innerHTML = '<span class="creative-progress-area"><span class="creative-progress-incomplete">0%</span></span>'
  row.requestUpdate = jest.fn()

  applyRowProperties(row, {
    templates: { progress_html: TOGGLE_HTML },
  })

  expect(row.progressHtml).toBe(TOGGLE_HTML)
  expect(row.dataset.progressHtml).toBe(TOGGLE_HTML)
  expect(row.requestUpdate).toHaveBeenCalledTimes(1)
})

test('replaces the progress control when a remote update changes binary eligibility', () => {
  const row = document.createElement('creative-tree-row')
  row.progressHtml = TOGGLE_HTML
  row.dataset.progressHtml = row.progressHtml
  row.requestUpdate = jest.fn()
  const partial = '<span class="creative-progress-incomplete">50%</span>'

  applyRowProperties(row, {
    inline_editor_payload: { progress: 0.5 },
    progress_control_html: partial,
  })

  expect(row.progressHtml).toBe(partial)

  applyRowProperties(row, {
    inline_editor_payload: { progress: 0 },
    progress_control_html: TOGGLE_HTML,
  })

  expect(row.progressHtml).toBe(TOGGLE_HTML)
})

test('preserves a dirty cron message when an incremental progress update rerenders the row', () => {
  const progressHtml = `
    <span data-cron-key="cron-42">
      <textarea data-cron-badge-target="messageInput"
                data-cron-saved-message="Saved message">Saved message</textarea>
    </span>
    ${TOGGLE_HTML}
  `
  const row = document.createElement('creative-tree-row')
  row.progressHtml = progressHtml
  row.dataset.progressHtml = progressHtml
  row.innerHTML = `<span class="creative-progress-area">${progressHtml}</span>`
  row.requestUpdate = jest.fn()
  row.querySelector('textarea').value = '\nHalf-typed message'

  applyRowProperties(row, {
    inline_editor_payload: { progress: 0.5 },
    progress_control_html: '<span class="creative-progress-incomplete">50%</span>',
  })

  const template = document.createElement('template')
  template.innerHTML = row.progressHtml
  const input = template.content.querySelector('textarea')
  expect(input.value).toBe('\nHalf-typed message')
  expect(input.dataset.cronSavedMessage).toBe('Saved message')
})

test('keeps in-flight cron controls disabled during DOM synchronization', () => {
  const progressHtml = `
    <span data-cron-badge-target="task" data-cron-key="cron-42">
      <textarea data-cron-badge-target="messageInput"
                data-cron-saved-message="Saved message">Saved message</textarea>
      <button data-action="click->cron-badge#saveMessage">Save</button>
    </span>
    ${TOGGLE_HTML}
  `
  const row = document.createElement('creative-tree-row')
  row.progressHtml = progressHtml
  row.dataset.progressHtml = progressHtml
  row.innerHTML = `<span class="creative-progress-area">${progressHtml}</span>`
  const input = row.querySelector('textarea')
  const button = row.querySelector('button[data-action]')
  input.value = 'Half-typed message'
  input.disabled = true
  button.disabled = true

  syncProgressHtmlFromDom(row)

  const template = document.createElement('template')
  template.innerHTML = row.progressHtml
  expect(template.content.querySelector('textarea').value).toBe('Half-typed message')
  expect(template.content.querySelector('textarea').disabled).toBe(true)
  expect(template.content.querySelector('button').disabled).toBe(true)
})
