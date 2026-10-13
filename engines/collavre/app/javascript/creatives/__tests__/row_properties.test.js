import { applyDisplayProgress, normalizeBoolean } from '../row_properties'

test('partial row updates preserve filtered progress; explicit null clears it', () => {
  const row = document.createElement('creative-tree-row')
  const payload = { progress: 1 }
  expect(applyDisplayProgress(row, { display_progress: 0, inline_editor_payload: payload })).toBe(payload)
  expect(row.dataset.displayProgress).toBe('0')
  expect(applyDisplayProgress(row, {})).toEqual({})
  expect(row.dataset.displayProgress).toBe('0')
  applyDisplayProgress(row, { display_progress: null })
  expect(row.hasAttribute('data-display-progress')).toBe(false)
})

test.each([[true, true], ['true', true], ['', true], [false, false], ['false', false], [undefined, false]])('normalizes row boolean %s to %s', (value, expected) => {
  expect(normalizeBoolean(value)).toBe(expected)
})
