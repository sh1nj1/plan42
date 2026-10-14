import { jest } from '@jest/globals'

jest.unstable_mockModule('../../lib/utils/dialog', () => ({
  confirmDialog: jest.fn().mockResolvedValue(true), alertDialog: jest.fn()
}))
const { default: AuthController } = await import('../agent_auth_controller')
const { default: CommentController } = await import('../comment_controller')
const { default: ImageController } = await import('../image_lightbox_controller')
const { default: GatewayController } = await import('../gateway_check_controller')
const { default: VersionController } = await import('../comment_version_controller')
const { alertDialog } = await import('../../lib/utils/dialog')

const own = (controller, properties) => {
  for (const [key, value] of Object.entries(properties)) {
    Object.defineProperty(controller, key, { value, configurable: true, writable: true })
  }
  return controller
}

describe('controller requests share CSRF token handling', () => {
  let originalFetch
  beforeEach(() => {
    originalFetch = global.fetch
    document.head.innerHTML = '<meta name="csrf-token" content="old-token">'
    global.fetch = jest.fn().mockResolvedValue({
      ok: true, headers: new Headers({ 'X-CSRF-Token': 'new-token' }),
      text: async () => '{"ok":true}', json: async () => ({ ok: true })
    })
  })
  afterEach(() => {
    global.fetch = originalFetch
    document.head.innerHTML = ''
    jest.clearAllMocks()
  })

  const assertToken = (method) => {
    const options = global.fetch.mock.calls[0][1]
    expect(options.method).toBe(method)
    expect(options.credentials).toBe('same-origin')
    expect(options.headers.get('X-CSRF-Token')).toBe('old-token')
    expect(document.querySelector('meta').content).toBe('new-token')
  }

  test('auth preserves JSON body, headers and parsed error behavior', async () => {
    const controller = Object.create(AuthController.prototype)
    const body = JSON.stringify({ code: 'secret' })
    expect(await controller.request('/auth', { method: 'POST', body })).toEqual({ ok: true })
    assertToken('POST')
    expect(fetch.mock.calls[0][1].body).toBe(body)
    expect(fetch.mock.calls[0][1].headers.get('Content-Type')).toBe('application/json')
    fetch.mockResolvedValueOnce({ ok: false, headers: new Headers(), text: async () => '{"error":{"message":"Denied"}}' })
    await expect(controller.request('/auth')).rejects.toThrow('Denied')
  })

  test('missing meta omits token and caller header override is retained', async () => {
    document.head.innerHTML = ''
    const controller = Object.create(AuthController.prototype)
    await controller.request('/auth')
    expect(fetch.mock.calls[0][1].headers.has('X-CSRF-Token')).toBe(false)
    await controller.request('/auth', { headers: { 'X-CSRF-Token': 'override' } })
    expect(fetch.mock.calls[1][1].headers.get('X-CSRF-Token')).toBe('override')
  })

  test.each([false, true])('reaction request keeps POST body/DELETE query for reacted=%s', async reacted => {
    const controller = own(Object.create(CommentController.prototype), {
      element: { dataset: { creativeId: '4', commentId: '7' } }, updateReactionsUI: jest.fn()
    })
    await controller.submitReaction('👍', reacted)
    assertToken(reacted ? 'DELETE' : 'POST')
    const [url, options] = fetch.mock.calls[0]
    if (reacted) {
      expect(new URL(url).searchParams.get('emoji')).toBe('👍')
      expect(options.body).toBeUndefined()
    } else expect(JSON.parse(options.body)).toEqual({ emoji: '👍' })
    expect(controller.updateReactionsUI).toHaveBeenCalledWith({ ok: true })
  })

  test('snapshot restore preserves failure UI and re-enables button', async () => {
    fetch.mockResolvedValueOnce({ ok: false, headers: new Headers({ 'X-CSRF-Token': 'new-token' }), json: async () => ({ error: 'Denied' }) })
    const controller = Object.create(CommentController.prototype)
    const button = { dataset: { snapshotId: '3', creativeId: '4', confirmText: 'Restore?' } }
    await controller.restoreSnapshot({ currentTarget: button })
    assertToken('POST')
    expect(button.disabled).toBe(false)
    expect(alertDialog).toHaveBeenCalledWith('Denied')
  })

  test('image removal non-OK retains image and carousel', async () => {
    fetch.mockResolvedValueOnce({ ok: false, headers: new Headers({ 'X-CSRF-Token': 'new-token' }) })
    const controller = own(Object.create(ImageController.prototype), {
      hasDownloadAllUrlValue: true, downloadAllUrlValue: '/download_images',
      i18nDeleteConfirmValue: 'Delete?', _currentIndex: 1, _images: ['a', 'b']
    })
    await controller._deleteCurrentImage()
    assertToken('DELETE')
    expect(fetch.mock.calls[0][0]).toBe('/remove_image?index=1')
    expect(controller._images).toEqual(['a', 'b'])
  })

  test('gateway displays result and restores button', async () => {
    const result = document.createElement('span')
    const button = { parentElement: { querySelector: () => result } }
    const controller = own(Object.create(GatewayController.prototype), { checkingValue: 'Checking', successValue: 'Connected' })
    await controller.check({ currentTarget: button, params: { url: '/gateway' } })
    assertToken('POST')
    expect(result.textContent).toBe('Connected ()')
    expect(button.disabled).toBe(false)
  })

  test('version select preserves selected state and rendering', async () => {
    const controller = own(Object.create(VersionController.prototype), {
      fetchVersions: async () => [{ id: 2 }], currentIndex: 1,
      versionsUrlValue: '/versions', selectedVersionId: 1, render: jest.fn()
    })
    await controller.selectVersion()
    assertToken('POST')
    expect(fetch.mock.calls[0][0]).toBe('/versions/2/select')
    expect(controller.selectedVersionId).toBe(2)
    expect(controller.render).toHaveBeenCalledTimes(1)
  })
  test('version deletion retains remaining metadata and renders selected version', async () => {
    fetch.mockResolvedValueOnce({ ok: true, headers: new Headers({ 'X-CSRF-Token': 'new-token' }),
      json: async () => ({ total: 2, selected_version_id: 3 }) })
    const versions = [{ id: 1 }, { id: 2 }, { id: 3 }]
    const controller = own(Object.create(VersionController.prototype), {
      fetchVersions: async () => versions, currentIndex: 2, versionsUrlValue: '/versions',
      deleteBtnTarget: { dataset: { confirmMessage: 'Delete?' } }, render: jest.fn()
    })
    await controller.deleteVersion()
    assertToken('DELETE')
    expect(fetch.mock.calls[0][0]).toBe('/versions/2')
    expect(versions.map(version => version.id)).toEqual([1, 3])
    expect(controller.currentIndex).toBe(2)
    expect(controller.render).toHaveBeenCalledTimes(1)
  })

})
