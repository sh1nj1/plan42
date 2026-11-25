/** @jest-environment jsdom */
import { setCreativeTitle } from '../creative_title'

test('updates text and original metadata, then clears creative metadata for an empty chat', () => {
  const title = document.createElement('h3')
  setCreativeTitle(title, '<b>Original</b>', '42')
  expect(title.textContent).toBe('<b>Original</b>')
  expect(title.children).toHaveLength(0)
  expect(title.dataset.creativeId).toBe('42')
  expect(title.dataset.originalLabel).toBe('<b>Original</b>')
  setCreativeTitle(title, 'Comments')
  expect(title.textContent).toBe('Comments')
  expect(title.dataset.creativeId).toBe('')
  expect(title.dataset.originalLabel).toBe('')
})
