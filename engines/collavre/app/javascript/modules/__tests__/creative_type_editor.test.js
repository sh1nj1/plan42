/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import { CreativeTypeEditor } from '../creative_type_editor'
import SearchCombobox from '../../lib/search_combobox'

let editor, form, onChange
beforeEach(() => {
  window.HTMLElement.prototype.scrollIntoView = jest.fn()
  document.body.innerHTML = `<form><div data-creative-type-editor data-add-label='Add type "%{name}"' data-save-failed="Save failed">
    <input id="type" role="combobox"><input type="hidden" name="creative[creative_type]" disabled>
    <div class="common-popup" style="display:none"><ul></ul></div><button type="button">Cancel</button><span role="alert"></span><a hidden>Rules</a>
  </div></form>`
  form = document.querySelector('form')
  form.firstChild.dataset.options = JSON.stringify([{ value: '', name: 'General' }, { value: 'workflow', name: 'Workflow' }])
  onChange = jest.fn()
  editor = new CreativeTypeEditor(form, onChange)
  editor.load({ id: 7, creative_type: '' })
})
afterEach(() => editor.popup.hide())

function search(text) {
  editor.input.focus()
  editor.input.value = text
  editor.input.dispatchEvent(new Event('input'))
}
function key(name, extra = {}) {
  const event = new KeyboardEvent('keydown', { key: name, bubbles: true, cancelable: true, ...extra })
  editor.input.dispatchEvent(event)
  return event
}

test('search is not submitted until an explicit selection, with keyboard accessibility', () => {
  search('work')
  expect(new FormData(form).has('creative[creative_type]')).toBe(false)
  expect(editor.input.getAttribute('aria-expanded')).toBe('true')
  expect(document.getElementById(editor.input.getAttribute('aria-activedescendant')).getAttribute('role')).toBe('option')
  expect(key('Enter').defaultPrevented).toBe(true)
  expect(editor.value).toBe('workflow')
  expect(new FormData(form).get('creative[creative_type]')).toBe('workflow')
  expect(editor.link.hidden).toBe(true)
  editor.saved({ id: 7, creative_type: 'workflow' }, 'workflow')
  expect(editor.link.hidden).toBe(false)
  expect(editor.link.getAttribute('href')).toBe('/creatives/7/edit')
  expect(editor.value).toBeUndefined()
})

test('normalizes and adds a custom type explicitly without injecting HTML', () => {
  search('  Ｐｒｏｊｅｃｔ   Ａ  ')
  expect(editor.popup.items).toEqual([{ name: 'Add type "project a"', value: 'project a', custom: true }])
  key('Enter')
  expect(editor.value).toBe('project a')
  search('PROJECT A')
  expect(editor.popup.items).toHaveLength(1)
  expect(editor.popup.items[0].custom).toBeUndefined()
  search('<img src=x>')
  expect(editor.root.querySelector('img')).toBeNull()
})

test.each(['Escape', 'Tab'])('%s cancels search without saving and preserves normal Tab navigation', name => {
  search('new type')
  const event = key(name)
  expect(editor.input.value).toBe('General')
  expect(editor.value).toBeUndefined()
  expect(onChange).not.toHaveBeenCalled()
  expect(event.defaultPrevented).toBe(name === 'Escape')
  expect(editor.input.hasAttribute('aria-activedescendant')).toBe(false)
})

test('blur cancels search, IME Enter does not add, and arrows navigate options', () => {
  search('new type')
  key('Enter', { isComposing: true })
  expect(editor.value).toBeUndefined()
  expect(key('a').defaultPrevented).toBe(false)
  editor.input.blur()
  expect(editor.input.value).toBe('General')
  editor.input.focus()
  key('ArrowDown')
  expect(editor.popup.activeIndex).toBe(1)
  key('ArrowUp')
  expect(editor.popup.activeIndex).toBe(0)
})

test('protected and too-long names cannot be added; existing system type is read only', () => {
  for (const value of ['INBOX', 'workflow_rule', 'x'.repeat(65)]) {
    search(value)
    expect(editor.popup.isOpen()).toBe(false)
  }
  editor.protectedLabels = { inbox: 'Inbox' }
  editor.load({ id: 7, creative_type: 'inbox' })
  expect(editor.input.disabled).toBe(true)
  expect(editor.input.value).toBe('Inbox')
})

test('cancel restores the saved type, while a newer selection survives an older response', () => {
  editor.load({ id: 7, creative_type: 'project' })
  search('workflow')
  key('Enter')
  editor.saved({ id: 7, creative_type: 'other' }, 'other')
  expect(editor.value).toBe('workflow')
  form.querySelector('button').click()
  expect(editor.value).toBe('other')
  editor.saved({}, 'other')
  expect(editor.value).toBeUndefined()
})

test('failed saves display server errors and keep the draft, with a localized fallback', async () => {
  search('workflow')
  key('Enter')
  for (const data of [{ errors: ['Admin required'] }, { error: 'Forbidden' }, {}]) {
    const response = { clone: () => ({ json: async () => data }) }
    expect(await editor.failed(response)).toBe(response)
    expect(editor.error.textContent).toBe(data.error || data.errors?.join(' ') || 'Save failed')
    expect(editor.value).toBe('workflow')
  }
  await editor.failed({ clone: () => ({ json: async () => { throw new Error('Network') } }) })
  expect(editor.error.textContent).toBe('Save failed')
})

test('close drains a newer pending type and refuses navigation on failed saves', async () => {
  search('workflow')
  key('Enter')
  const save = jest.fn().mockResolvedValueOnce(undefined).mockImplementationOnce(async () => {
    editor.saved({ id: 7, creative_type: 'workflow' }, 'workflow')
  })
  await editor.flush(save)
  expect(save).toHaveBeenCalledTimes(2)
  const close = jest.fn()
  expect(await editor.beforeMove(close)).toBe(true)
  expect(close).not.toHaveBeenCalled()
  search('custom')
  key('Enter')
  const failed = jest.fn().mockResolvedValue({ ok: false })
  expect(await editor.flush(failed)).toEqual({ ok: false })
  expect(failed).toHaveBeenCalledTimes(1)
  expect(await editor.beforeMove(async () => 'save-failed')).toBe(false)
  expect(await editor.beforeMove(async () => undefined)).toBe(true)
})

test('shared selector can disable custom additions and accept a label accessor', () => {
  const popup = new SearchCombobox(editor.popup.element, { input: editor.input })
  popup.showOptions([{ label: 'Model' }], 'unknown', { label: item => item.label })
  expect(popup.isOpen()).toBe(false)
  popup.showOptions([{ label: 'Model' }], 'mod', { label: item => item.label })
  expect(popup.items).toHaveLength(1)
  popup.hide()
})

test('missing template tolerates loading, saving and failure handling', async () => {
  const absent = new CreativeTypeEditor(document.createElement('form'), onChange)
  absent.load()
  absent.saved({}, '')
  const response = {}
  expect(await absent.failed(response)).toBe(response)
  expect(absent.value).toBeUndefined()
})

test('late responses only update the session they saved', () => {
  const first = {}, second = {}
  editor.acknowledgeSave({}, { id: 7, creative_type: 'workflow' }, second, first)
  expect(editor.link.hidden).toBe(true)
  editor.acknowledgeSave({}, { id: 7, creative_type: 'workflow' }, first, first)
  expect(editor.link.hidden).toBe(false)
  editor.acknowledgeSave({}, { id: 7, creative_type: '' }, null, first)
  expect(editor.link.hidden).toBe(true)
})


test('unsaved type remains flushable after an autosave failure and teardown closes the popup', () => {
  expect(editor.needsFlush(false, false)).toBe(false)
  expect(editor.needsFlush(true, false)).toBe(true)
  expect(editor.needsFlush(false, true)).toBe(true)
  search('workflow')
  key('Enter')
  expect(editor.needsFlush(false, false)).toBe(true)
  search('new type')
  editor.dispose()
  expect(editor.popup.isOpen()).toBe(false)
  new CreativeTypeEditor(document.createElement('form'), onChange).dispose()
})


test('body-only acknowledgment refreshes a type changed by another session', () => {
  editor.saved({ id: 7, creative_type: 'workflow' }, undefined)
  expect(editor.input.value).toBe('Workflow')
  expect(editor.link.hidden).toBe(false)
  expect(editor.value).toBeUndefined()
  editor.saved({ id: 7, creative_type: 'project' }, undefined)
  expect(editor.input.value).toBe('project')
  search('project')
  expect(editor.popup.items).toEqual([{ name: 'project', value: 'project' }])
})

test('body-only acknowledgment preserves a new pending selection', () => {
  search('custom')
  key('Enter')
  editor.saved({ id: 7, creative_type: 'workflow' }, undefined)
  expect(editor.input.value).toBe('custom')
  expect(editor.value).toBe('custom')
  expect(editor.link.hidden).toBe(true)
  form.querySelector('button').click()
  expect(editor.input.value).toBe('Workflow')
})
