import { jest } from '@jest/globals'
import { updatePermission } from '../permission_update'

describe('permission update transaction', () => {
  let select, onFailure
  beforeEach(() => {
    document.head.innerHTML = '<meta name="csrf-token" content="token">'
    document.body.innerHTML = '<select class="extra org-chart-permission-read" data-update-url="/shares/1"><option value="write" selected>Write</option></select>'
    select = document.querySelector('select')
    onFailure = jest.fn()
    global.fetch = jest.fn().mockResolvedValue({ ok: true })
  })
  test('updates styling optimistically and preserves PATCH headers and body', async () => {
    const pending = updatePermission(select, { classes: ['share-modal-permission-select'], onFailure })
    expect(select.classList.contains('org-chart-permission-write')).toBe(true)
    expect(select.classList.contains('org-chart-permission-read')).toBe(false)
    expect(select.classList.contains('extra')).toBe(true)
    expect(select.classList.contains('share-modal-permission-select')).toBe(true)
    await pending
    expect(fetch).toHaveBeenCalledWith('/shares/1', {
      method: 'PATCH', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': 'token', Accept: 'application/json' }, body: '{"permission":"write"}'
    })
    expect(onFailure).not.toHaveBeenCalled()
  })
  test.each(['non-ok', 'network'])('restores original class before caller-specific failure on %s', async kind => {
    const original = select.className
    if (kind === 'non-ok') fetch.mockResolvedValue({ ok: false })
    else fetch.mockRejectedValue(new Error('offline'))
    onFailure.mockImplementation(() => expect(select.className).toBe(original))
    await updatePermission(select, { onFailure })
    expect(onFailure).toHaveBeenCalledTimes(1)
  })
  test('preserves missing-token header behavior', async () => {
    document.head.innerHTML = ''
    await updatePermission(select, { onFailure })
    expect(fetch.mock.calls[0][1].headers['X-CSRF-Token']).toBeUndefined()
  })
})
