/**
 * @jest-environment jsdom
 */
import { updateProgressHtml } from '../tree_renderer'

const TOGGLE_HTML = '<span class="progress-toggle-wrap" data-progress-toggle="true" data-current-progress="0" data-new-progress="1" data-mark-complete="Mark complete" data-mark-incomplete="Mark incomplete" title="Mark complete"><input type="checkbox" class="progress-toggle-checkbox" aria-label="Mark complete"></span>'

test('updates checkbox markup and the next action for binary progress broadcasts', () => {
  const complete = updateProgressHtml(TOGGLE_HTML, 1, '100%')
  expect(complete).toContain('checked="checked"')
  expect(complete).toContain('data-current-progress="1"')
  expect(complete).toContain('data-new-progress="0"')
  expect(complete).toContain('title="Mark incomplete"')

  const incomplete = updateProgressHtml(complete, 0, '0%')
  expect(incomplete).not.toContain('checked="checked"')
  expect(incomplete).toContain('data-current-progress="0"')
  expect(incomplete).toContain('data-new-progress="1"')
  expect(incomplete).toContain('title="Mark complete"')
})

test('keeps percentage markup working for non-interactive progress', () => {
  const html = '<span class="creative-progress-incomplete">0%</span>'

  expect(updateProgressHtml(html, 0.5, '50%')).toBe('<span class="creative-progress-incomplete">50%</span>')
  expect(updateProgressHtml(html, 1, '✓')).toBe('<span class="creative-progress-complete">✓</span>')
})
