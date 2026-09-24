/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import AgentVendorController from '../agent_vendor_controller'

const tick = () => new Promise((resolve) => setTimeout(resolve, 0))
const EFFORTS = JSON.stringify({
  claude: ['low', 'medium', 'high', 'xhigh', 'max'],
  codex: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'],
  codex_custom: ['none', 'minimal', 'low', 'medium', 'high', 'xhigh'],
})

describe('agent-vendor run options', () => {
  let application

  const render = async ({ vendor = 'cli_proxy', model = 'paperclip/claude_local', effort = '' } = {}) => {
    document.body.innerHTML = `
      <div data-controller="agent-vendor" data-agent-vendor-default-model-value="paperclip/claude_local">
        <select data-agent-vendor-target="vendor" data-action="change->agent-vendor#update">
          <option value="google">google</option><option value="cli_proxy">cli_proxy</option>
        </select>
        <div data-agent-vendor-target="gateway"><select data-agent-vendor-target="gatewaySelect"></select></div>
        <div data-agent-vendor-target="legacyCredential"></div>
        <input data-agent-vendor-target="model" value="${model}">
        <div data-agent-vendor-target="runOptions">
          <select data-agent-vendor-target="effort" data-efforts='${EFFORTS}'>
            <option value="">Proxy default</option>
            ${['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].map((v) => `<option value="${v}">${v}</option>`).join('')}
          </select>
        </div>
        <div data-agent-vendor-target="fastMode"><input type="checkbox" data-agent-vendor-target="fastModeCheckbox"></div>
      </div>`
    document.querySelector('[data-agent-vendor-target="vendor"]').value = vendor
    document.querySelector('[data-agent-vendor-target="effort"]').value = effort
    application = Application.start()
    application.register('agent-vendor', AgentVendorController)
    await tick()
  }

  const el = (target) => document.querySelector(`[data-agent-vendor-target="${target}"]`)
  const visibleEfforts = () => Array.from(el('effort').options).filter((o) => !o.hidden && o.value).map((o) => o.value)

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('claude models offer claude levels and no fast mode', async () => {
    await render({ effort: 'max' })
    expect(el('runOptions').hidden).toBe(false)
    expect(visibleEfforts()).toEqual(['low', 'medium', 'high', 'xhigh', 'max'])
    expect(el('effort').value).toBe('max')
    expect(el('fastMode').hidden).toBe(true)
  })

  test('switching to codex_local clears an unsupported level and shows fast mode', async () => {
    await render({ effort: 'max' })
    el('model').value = 'paperclip/codex_local/gpt-5.5'
    el('model').dispatchEvent(new Event('input'))

    expect(visibleEfforts()).toEqual(['none', 'minimal', 'low', 'medium', 'high', 'xhigh'])
    expect(el('effort').value).toBe('')
    expect(el('fastMode').hidden).toBe(false)
  })

  test('hides run options outside the paperclip namespace or another vendor', async () => {
    await render({ model: 'gpt-4o' })
    expect(el('runOptions').hidden).toBe(true)
    expect(el('fastMode').hidden).toBe(true)

    application.stop()
    await render({ vendor: 'google', model: 'paperclip/codex_local' })
    expect(el('runOptions').hidden).toBe(true)
    expect(el('gateway').hidden).toBe(true)
  })

  test('fills the default model when cli_proxy is chosen with none', async () => {
    await render({ vendor: 'google', model: '' })
    el('vendor').value = 'cli_proxy'
    el('vendor').dispatchEvent(new Event('change'))
    expect(el('model').value).toBe('paperclip/claude_local')
    expect(el('runOptions').hidden).toBe(false)
  })
})
