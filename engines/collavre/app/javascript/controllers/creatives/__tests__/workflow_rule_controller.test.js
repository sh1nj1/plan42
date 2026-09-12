/** @jest-environment jsdom */
import { jest } from '@jest/globals'
import fs from 'node:fs'
const csrfFetch = jest.fn()
jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({ default: csrfFetch }))
const { Application } = await import('@hotwired/stimulus')
const Controller = (await import('../workflow_rule_controller')).default
const labels = { title: 'Rules', add_rule: 'Add rule', saved: 'Saved', load_failed: 'Load failed', save_failed: 'Save failed', invalid_json: 'Invalid JSON', raw_pending: 'Apply JSON first', read_only: 'Read only', empty: 'No rules', remove_phrase: 'Remove phrase', agent_unavailable: 'Unavailable', agent_cannot_respond_here: 'Cannot respond', events: { comment_created: 'Comment' }, source_labels: { cron: 'Schedule' } }
const payload = { on: 'comment_created', handler: { type: 'human', future: true }, when: { source: [], body_contains: [], liquid: '', future: 3 }, emits: 'future_event', extra: { safe: true } }
const rule = (raw = payload) => ({ id: 2, description: '<img src=x onerror=alert(1)>Title', rule: raw, errors: ['<b>Advisory</b>'], warnings: [], can_manage: true })
const data = (rules = [rule()], manage = true) => ({ workflow_id: 1, event_names: ['comment_created', 'future_event'], sources_by_event: { comment_created: ['cron', 'a2a'], future_event: ['future_source'] }, agents: [{ id: 5, name: 'Bot', can_respond_here: false, warnings: ['Cannot respond'] }], rules, can_manage: manage, permission_note: 'Target permissions apply' })
const tick = () => new Promise(resolve => setTimeout(resolve, 0))
let application, root, controller
function markup() {
  let template = fs.readFileSync('engines/collavre/app/views/collavre/creatives/_workflow_panel.html.erb', 'utf8').match(/<template[\s\S]*<\/template>/)[0]
  template = template.replace(/<% %w\[agent human none\].each do \|type\| %>([\s\S]*?)<% end %>/, (_, html) => ['agent', 'human', 'none'].map(type => html.replaceAll('<%= type %>', type)).join(''))
  template = template.replace(/<%=[\s\S]*?%>/g, 'Label')
  document.body.innerHTML = `<section data-controller="creatives--workflow-rule" data-creatives--workflow-rule-url-value="/creatives/1/workflow" data-creatives--workflow-rule-create-url-value="/creatives/1/workflow_rule" data-creatives--workflow-rule-rule-url-value="/creatives/RULE_ID/workflow_rule"><p data-creatives--workflow-rule-target="permission"></p><p data-creatives--workflow-rule-target="status"></p><div data-creatives--workflow-rule-target="rules"></div><button data-creatives--workflow-rule-target="create"></button>${template}</section>`
  root = document.querySelector('section')
  root.setAttribute('data-creatives--workflow-rule-labels-value', JSON.stringify(labels))
}
async function mount(response = data()) {
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => response })
  markup()
  application = Application.start()
  application.register('creatives--workflow-rule', Controller)
  await tick(); await tick()
  controller = application.getControllerForElementAndIdentifier(root, 'creatives--workflow-rule')
}
const form = () => root.querySelector('form')
function change(name, value) {
  const input = form().querySelector(`[name="${name}"]`)
  if (input.type === 'checkbox') input.checked = value
  else input.value = value
  input.dispatchEvent(new Event('change', { bubbles: true }))
}
function submit() { form().dispatchEvent(new Event('submit', { bubbles: true, cancelable: true })) }
afterEach(() => { application?.stop(); document.body.replaceChildren(); csrfFetch.mockReset() })

test('loads vocabulary and renders descriptions and diagnostics as text', async () => {
  await mount()
  expect(form().textContent).toContain('<b>Advisory</b>')
  expect(form().querySelector('img')).toBeNull()
  expect(form().querySelector('h3').textContent).toBe(rule().description)
  expect(form().querySelector('[name="event"]').options[0].text).toBe('Comment')
  expect(form().querySelector('[name="agents"]').multiple).toBe(true)
  expect(root.textContent).toContain('Target permissions apply')
})

test.each([
  'Handle <script> examples',
  '<script>alert(1)</script>',
  'Compare <b>bold</b> & &lt;literal&gt;',
  '배포 <조건> 처리'
])('preserves title %s as literal text through save and reload', async description => {
  const record = { ...rule(), description }
  await mount(data([record]))
  const assertTitle = () => {
    const heading = form().querySelector('h3')
    expect(heading.textContent).toBe(description)
    expect(heading.childElementCount).toBe(0)
  }
  assertTitle()
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => record })
  submit(); await tick()
  expect(root.textContent).toContain('Saved')
  assertTitle()
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => data([record]) })
  await controller.load()
  assertTitle()
})

test('saves changed author while retaining explicit empty conditions, unknown fields and emits', async () => {
  await mount()
  change('author', 'yes')
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => rule({ ...payload, when: { ...payload.when, author_agent: true } }) })
  submit(); await tick()
  const [url, options] = csrfFetch.mock.calls.at(-1)
  expect(url).toBe('/creatives/2/workflow_rule')
  expect(options.method).toBe('PATCH')
  expect(JSON.parse(options.body).workflow_rule).toEqual({ ...payload, when: { ...payload.when, author_agent: true } })
  expect(root.textContent).toContain('Saved')
})

test.each([{ errors: ['Rejected'] }, { error: 'Forbidden' }])('keeps input and displays request diagnostics on failed save %j', async (error) => {
  await mount()
  change('author', 'no')
  csrfFetch.mockResolvedValueOnce({ ok: false, json: async () => error })
  submit(); await tick()
  expect(form().querySelector('[name="author"]').value).toBe('no')
  expect(form().textContent).toContain(error.error || error.errors[0])
})

test('readers see disabled controls and cannot create or save', async () => {
  await mount(data([{ ...rule(), can_manage: false }], false))
  expect(form().querySelector('fieldset').disabled).toBe(true)
  expect(root.textContent).toContain('Read only')
  controller.add(); submit(); await tick()
  expect(root.querySelectorAll('form')).toHaveLength(1)
  expect(csrfFetch).toHaveBeenCalledTimes(1)
})

test('rule permission overrides disable saving while workflow creation remains available', async () => {
  await mount(data([{ ...rule(), can_manage: false }]))
  expect(form().querySelector('fieldset').disabled).toBe(true)
  expect(form().textContent).toContain('Read only')
  expect(root.querySelector('[data-creatives--workflow-rule-target="create"]').disabled).toBe(false)
  submit(); await tick()
  expect(csrfFetch).toHaveBeenCalledTimes(1)
  controller.add()
  expect(root.querySelectorAll('form')[1].querySelector('fieldset').disabled).toBe(false)
})

test('read-only placement still allows manageable origin rules to save', async () => {
  await mount(data([rule()], false))
  expect(form().querySelector('fieldset').disabled).toBe(false)
  expect(root.textContent).not.toContain('Read only')
  expect(root.querySelector('[data-creatives--workflow-rule-target="create"]').disabled).toBe(true)
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => rule() })
  submit(); await tick()
  expect(csrfFetch.mock.calls.at(-1)[1].method).toBe('PATCH')
  expect(form().querySelector('fieldset').disabled).toBe(false)
})

test('creates a titled rule with selected event, agent warning and phrases', async () => {
  await mount(data([]))
  controller.add(); await tick()
  form().querySelector('[name="title"]').value = 'New rule'
  const radio = form().querySelector('[value="agent"]'); radio.checked = true
  radio.dispatchEvent(new Event('change', { bubbles: true }))
  change('agents', '5')
  expect(form().textContent).toContain('Cannot respond')
  form().querySelector('[name="phrase"]').value = 'hello'
  form().querySelector('[name="phrase"]').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }))
  csrfFetch.mockResolvedValueOnce({ ok: true, json: async () => ({ ...rule(), description: 'New rule' }) })
  submit(); await tick()
  const [url, options] = csrfFetch.mock.calls.at(-1)
  expect(url).toBe('/creatives/1/workflow_rule')
  expect(options.method).toBe('POST')
  expect(JSON.parse(options.body)).toEqual({ description: 'New rule', workflow_rule: { on: 'comment_created', handler: { type: 'agent', agent_ids: [5] }, when: { body_contains: ['hello'] } } })
})

test('malformed payload can be repaired via explicit JSON apply without executing HTML', async () => {
  await mount(data([rule(null)]))
  const raw = form().querySelector('[name="raw"]')
  raw.value = '{bad'
  controller.applyRaw({ target: raw })
  expect(form().textContent).toContain('Invalid JSON')
  raw.value = JSON.stringify({ on: 'comment_created', handler: { type: 'none' }, extra: '<img src=x>' })
  controller.applyRaw({ target: raw })
  expect(form().querySelector('[value="none"]').checked).toBe(true)
  expect(form().querySelector('img')).toBeNull()
})

test('sources follow vocabulary while unknown selected values are preserved until explicitly cleared', async () => {
  await mount(data([rule({ ...payload, when: { source: ['future_source'] } })]))
  expect(form().querySelector('[name="source"][value="future_source"]').checked).toBe(true)
  change('event', 'future_event')
  expect(form().querySelector('[name="source"][value="cron"]')).toBeNull()
  change('any-source', true)
  change('any-source', false)
  change('source', true)
  change('author', 'yes'); change('author', 'any')
  csrfFetch.mockResolvedValueOnce({ ok: false, json: async () => ({ error: 'Inspect' }) })
  submit(); await tick()
  expect(JSON.parse(csrfFetch.mock.calls.at(-1)[1].body).workflow_rule.when).toEqual({ source: ['future_source'] })
})

test('phrase tags add uniquely, ignore empty/IME/non-Enter input, and remove individually', async () => {
  await mount()
  const phrase = form().querySelector('[name="phrase"]')
  controller.addPhrase({ target: phrase })
  phrase.value = 'one'
  for (const options of [{ key: 'Enter', isComposing: true }, { key: 'a' }]) phrase.dispatchEvent(new KeyboardEvent('keydown', { ...options, bubbles: true }))
  expect(form().querySelectorAll('[data-index]')).toHaveLength(0)
  controller.addPhrase({ target: phrase })
  phrase.value = 'one'; controller.addPhrase({ target: phrase })
  phrase.value = 'two'; controller.addPhrase({ target: phrase })
  expect(form().querySelectorAll('[data-index]')).toHaveLength(2)
  await tick()
  form().querySelector('[data-index="0"]').click()
  expect(form().querySelectorAll('[data-index]')).toHaveLength(1)
  change('any-body', true)
  expect(form().querySelectorAll('[data-index]')).toHaveLength(0)
  change('any-body', false)
  expect(form().querySelector('[name="any-body"]').checked).toBe(false)
})

test('Liquid input updates only Liquid and any switch removes the condition explicitly', async () => {
  await mount()
  const expression = form().querySelector('[name="expression"]')
  expression.value = 'comment.content != blank'
  expression.dispatchEvent(new Event('input', { bubbles: true }))
  expect(form().querySelector('[name="any-liquid"]').checked).toBe(false)
  change('any-liquid', true)
  expect(JSON.parse(form().querySelector('[name="raw"]').value).when).not.toHaveProperty('liquid')
  change('any-liquid', false)
  expect(JSON.parse(form().querySelector('[name="raw"]').value).when.liquid).toBe('')
})

test('pending raw JSON is retained across form changes and blocks save until applied', async () => {
  await mount()
  const raw = form().querySelector('[name="raw"]')
  raw.value = JSON.stringify({ on: 'comment_created', handler: { type: 'none' } })
  raw.dispatchEvent(new Event('input', { bubbles: true }))
  change('author', 'yes')
  expect(JSON.parse(raw.value)).not.toHaveProperty('when')
  submit(); await tick()
  expect(csrfFetch).toHaveBeenCalledTimes(1)
  expect(form().textContent).toContain('Apply JSON first')
  raw.value = '[]'; controller.applyRaw({ target: raw })
  expect(form().textContent).toContain('Invalid JSON')
})

test.each([null, false, [], 'broken', { on: 'unknown', handler: [], when: 'broken' }, { on: 'constructor' }, { on: '__proto__' }])('malformed rule %j can be repaired with basic controls without crashing', async raw => {
  await mount(data([rule(raw)]))
  change('event', 'comment_created')
  const handler = form().querySelector('[value="none"]')
  handler.checked = true; handler.dispatchEvent(new Event('change', { bubbles: true }))
  change('author', 'no')
  expect(JSON.parse(form().querySelector('[name="raw"]').value)).toEqual({ on: 'comment_created', handler: { type: 'none' }, when: { author_agent: false } })
})

test.each([
  { on: { toString: null } },
  { on: 'comment_created', handler: { type: 'agent', agent_ids: [{ toString: null }] } },
  { on: 'comment_created', when: { source: [{ toString: null }], body_contains: [{ toString: null }] } }
])('malformed object values remain available in raw JSON for repair %j', async raw => {
  await mount(data([rule(raw), rule()]))
  expect(root.querySelectorAll('form')).toHaveLength(2)
  expect(JSON.parse(form().querySelector('[name="raw"]').value)).toEqual(raw)
  const input = form().querySelector('[name="raw"]')
  input.value = JSON.stringify({ on: 'comment_created', handler: { type: 'none' } })
  controller.applyRaw({ target: input })
  expect(form().querySelector('[value="none"]').checked).toBe(true)
})

test('unavailable agent IDs remain selected with a localized warning', async () => {
  await mount(data([rule({ ...payload, handler: { type: 'agent', agent_ids: [999] } })]))
  expect(form().querySelector('[name="agents"] option[value="999"]').selected).toBe(true)
  expect(form().textContent).toContain('Unavailable')
})

test.each([
  { ok: false }, { ok: true, redirected: true },
  { ok: true, json: async () => { throw new Error('HTML login page') } }
])('load failure %j displays localized retry text', async response => {
  csrfFetch.mockResolvedValueOnce(response)
  markup(); application = Application.start(); application.register('creatives--workflow-rule', Controller)
  await tick(); await tick()
  expect(root.textContent).toContain('Load failed')
  expect(root.querySelector('[data-creatives--workflow-rule-target="create"]').disabled).toBe(true)
})

test('aborted reload does not replace status with a failure', async () => {
  await mount()
  csrfFetch.mockRejectedValueOnce(new DOMException('Aborted', 'AbortError'))
  await controller.load()
  expect(root.textContent).not.toContain('Load failed')
})

test.each([
  { ok: true, redirected: true }, { ok: false, json: async () => ({}) },
  { ok: true, json: async () => { throw new Error('Invalid response') } }
])('unexpected save failure %j retains changes and re-enables controls', async response => {
  await mount()
  change('author', 'no')
  csrfFetch.mockResolvedValueOnce(response)
  submit(); await tick()
  expect(form().textContent).toContain('Save failed')
  expect(form().querySelector('[name="author"]').value).toBe('no')
  expect(form().querySelector('fieldset').disabled).toBe(false)
})

test('network save failure and duplicate submit never discard changes', async () => {
  await mount()
  let reject
  csrfFetch.mockImplementationOnce(() => new Promise((_, failure) => { reject = failure }))
  submit(); submit()
  expect(csrfFetch).toHaveBeenCalledTimes(2)
  reject(new Error('offline')); await tick()
  expect(form().textContent).toContain('Save failed')
})

 test('disconnect cancels pending load', async () => {
  await mount()
  const signal = csrfFetch.mock.calls[0][1].signal
  controller.disconnect()
  expect(signal.aborted).toBe(true)
})
