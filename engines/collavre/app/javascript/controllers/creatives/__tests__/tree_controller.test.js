/**
 * @jest-environment jsdom
 */

import { jest } from '@jest/globals'

jest.unstable_mockModule('../../../creatives/tree_renderer', () => ({
  renderCreativeTree: jest.fn(),
  appendCreativeNodes: jest.fn(),
  dispatchCreativeTreeUpdated: jest.fn(),
  applyRowProperties: jest.fn(),
}))

jest.unstable_mockModule('../../../utils/emoji_parser', () => ({
  parseEmojis: jest.fn(() => ['✨']),
}))

const { Application } = await import('@hotwired/stimulus')
const TreeController = (await import('../tree_controller')).default
const { appendCreativeNodes, renderCreativeTree } = await import('../../../creatives/tree_renderer')
const { restoreTreeEmptyState } = await import('../../../modules/creative_tree_empty_state')

const TRANSIENT_RETRY_DELAYS = [200, 600]

const flush = () => new Promise((resolve) => setTimeout(resolve, 0))

const collectRetryDelays = (spy) =>
  spy.mock.calls
    .map((args) => args[1])
    .filter((delay) => TRANSIENT_RETRY_DELAYS.includes(delay))

const installController = () => {
  const container = document.createElement('div')
  container.setAttribute('data-controller', 'creatives--tree')
  container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
  container.setAttribute('data-creatives--tree-loading-text-value', 'Loading creatives')
  document.body.appendChild(container)

  const application = Application.start()
  application.register('creatives--tree', TreeController)

  return { container, application }
}

describe('CreativesTreeController retry on transient network errors', () => {
  let originalFetch
  let setTimeoutSpy

  beforeEach(() => {
    originalFetch = global.fetch
    setTimeoutSpy = jest.spyOn(global, 'setTimeout')
  })

  afterEach(() => {
    setTimeoutSpy.mockRestore()
    global.fetch = originalFetch
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('schedules 200ms then 600ms backoff retry on TypeError "Failed to fetch"', async () => {
    global.fetch = jest
      .fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [] }),
      })

    const { application } = installController()
    // Allow time for the 200ms + 600ms retries to fire
    await new Promise((resolve) => setTimeout(resolve, 1000))

    expect(collectRetryDelays(setTimeoutSpy)).toEqual(TRANSIENT_RETRY_DELAYS)

    application.stop()
  })

  test('ignores a queued network retry after a new reload takes ownership', async () => {
    global.fetch = jest.fn()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValue({ ok: true, json: async () => ({ creatives: [{ id: 2 }] }) })
    const { container, application } = installController()
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.load({ preserveView: true })
    await flush()
    await new Promise(resolve => setTimeout(resolve, 250))
    expect(global.fetch).toHaveBeenCalledTimes(2)
    expect(renderCreativeTree).toHaveBeenLastCalledWith(container, [{ id: 2 }])
    application.stop()
  })

  test('discards a late JSON response even when the transport ignores abort', async () => {
    let releaseJson
    global.fetch = jest.fn()
      .mockResolvedValueOnce({ ok: true, json: () => new Promise(resolve => { releaseJson = resolve }) })
      .mockResolvedValueOnce({ ok: true, json: async () => ({ creatives: [{ id: 2 }] }) })
    const { container, application } = installController()
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.load({ preserveView: true })
    await flush()
    releaseJson({ creatives: [{ id: 1 }] })
    await flush()
    expect(renderCreativeTree).toHaveBeenLastCalledWith(container, [{ id: 2 }])
    expect(renderCreativeTree.mock.calls.filter(([target, nodes]) => target === container && nodes[0]?.id === 1)).toEqual([])
    application.stop()
  })

  test('does NOT schedule retry on HTTP error responses', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: async () => ({}),
    })

    const { application } = installController()
    await flush()
    await flush()
    await flush()

    expect(collectRetryDelays(setTimeoutSpy)).toEqual([])

    application.stop()
  })

  test('does NOT schedule retry on AbortError', async () => {
    const abortErr = new Error('aborted')
    abortErr.name = 'AbortError'
    global.fetch = jest.fn().mockRejectedValue(abortErr)

    const { application } = installController()
    await flush()
    await flush()

    expect(collectRetryDelays(setTimeoutSpy)).toEqual([])

    application.stop()
  })

  test('gives up after exactly 2 retries on persistent transient errors', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    const { container, application } = installController()
    // Allow time for both retries to complete (200 + 600 = 800ms)
    await new Promise((resolve) => setTimeout(resolve, 1500))

    expect(collectRetryDelays(setTimeoutSpy)).toEqual(TRANSIENT_RETRY_DELAYS)
    expect(container.dataset.loadState).toBe('error')
    expect(container.dataset.loaded).toBe('true')

    application.stop()
  })
})

describe('CreativesTreeController cron message drafts', () => {
  let originalFetch

  const cronTask = (message, { editable = true } = {}) => `
    <span data-cron-key="creative-1">
      ${editable
        ? `<textarea data-cron-badge-target="messageInput"
                     data-cron-saved-message="${message}">${message}</textarea>`
        : `<span class="cron-task-message">${message}</span>`}
    </span>
  `

  const cronRow = (message, options = {}) => `
    <creative-tree-row creative-id="1">${cronTask(message, options)}</creative-tree-row>
  `

  const installCachedTree = async (html) => {
    const container = document.createElement('div')
    container.setAttribute('data-controller', 'creatives--tree')
    container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
    container.setAttribute('data-creatives--tree-loading-text-value', 'Loading creatives')
    container.dataset.loaded = 'true'
    container.innerHTML = html
    document.body.appendChild(container)

    const application = Application.start()
    application.register('creatives--tree', TreeController)
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    return { container, application, controller }
  }

  beforeEach(() => {
    originalFetch = global.fetch
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [{ id: 1 }] }),
    })
  })

  afterEach(() => {
    global.fetch = originalFetch
    renderCreativeTree.mockReset()
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('preserves a dirty cron message across a preserved tree reload', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    container.querySelector('textarea').value = 'Half-typed message'
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = cronRow('Server message')
    })

    controller.load({ preserveView: true })
    await flush()
    await flush()

    const input = container.querySelector('textarea')
    expect(input.value).toBe('Half-typed message')
    expect(input.dataset.cronSavedMessage).toBe('Server message')
    application.stop()
  })

  test('waits for Lit rows to render before restoring a dirty cron message', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    container.querySelector('textarea').value = 'Half-typed message'
    let finishRowUpdate
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
      const row = element.querySelector('creative-tree-row')
      row.updateComplete = new Promise((resolve) => {
        finishRowUpdate = () => {
          row.innerHTML = cronTask('Server message')
          resolve(true)
        }
      })
    })

    controller.load({ preserveView: true })
    await flush()
    await flush()

    expect(container.querySelector('textarea')).toBeNull()
    finishRowUpdate()
    await flush()

    const input = container.querySelector('textarea')
    expect(input.value).toBe('Half-typed message')
    expect(input.dataset.cronSavedMessage).toBe('Server message')
    application.stop()
  })

  test('does not restore a dirty cron message into a superseded Lit render', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    const drafts = new Map([['creative-1', 'Half-typed message']])
    controller._pendingCronMessageDrafts = drafts
    let finishRowUpdate
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
      const row = element.querySelector('creative-tree-row')
      row.updateComplete = new Promise((resolve) => {
        finishRowUpdate = () => {
          row.innerHTML = cronTask('Server message')
          resolve(true)
        }
      })
    })

    const rendering = controller.renderData({ creatives: [{ id: 1 }] })
    controller._viewRestoreGeneration += 1
    finishRowUpdate()
    await rendering

    expect(container.querySelector('textarea').value).toBe('Server message')
    expect(controller._pendingCronMessageDrafts).toBe(drafts)
    application.stop()
  })

  test('captures newer edits while view-state restoration is still pending', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    let releaseChildren
    global.fetch = jest.fn((url) => {
      if (url === '/children/1') {
        return new Promise((resolve) => {
          releaseChildren = () => resolve({
            ok: true,
            headers: new Headers(),
            json: async () => ({ creatives: [{ id: 2 }] }),
          })
        })
      }
      return new Promise(() => {})
    })
    const originalDrafts = new Map([['creative-1', 'First draft']])
    controller._pendingCronMessageDrafts = originalDrafts
    controller._pendingViewState = {
      scrolling: document.documentElement,
      scrollTop: 0,
      focus: null,
      expansion: [{ creativeId: '1', expanded: true }],
    }
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = `
        <creative-tree-row creative-id="1" has-children>
          ${cronTask('Server message')}
        </creative-tree-row>
        <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
      `
    })

    const restoration = controller.renderData({ creatives: [{ id: 1 }] })
    await flush()

    const input = container.querySelector('textarea')
    expect(input.value).toBe('First draft')
    expect(controller._pendingCronMessageDrafts).toBeNull()

    input.value = 'Newer draft'
    controller.load({ preserveView: true })

    expect(controller._pendingCronMessageDrafts).toEqual(new Map([
      ['creative-1', 'Newer draft'],
    ]))

    releaseChildren()
    await restoration

    expect(controller._pendingCronMessageDrafts).toEqual(new Map([
      ['creative-1', 'Newer draft'],
    ]))
    controller.stopAnimation()
    application.stop()
  })

  test('restores a dirty cron message after loading an expanded branch', async () => {
    const { container, application, controller } = await installCachedTree(`
      <creative-tree-row creative-id="1" has-children expanded></creative-tree-row>
      <div id="creative-children-1" data-loaded="true">
        <creative-tree-row creative-id="2">${cronTask('Saved message')}</creative-tree-row>
      </div>
    `)
    const draftInput = container.querySelector('textarea')
    draftInput.closest('[data-cron-key]').dataset.cronKey = 'creative-2'
    draftInput.value = 'Half-typed child message'
    let finishChildUpdate
    global.fetch = jest.fn((url) => {
      if (url === '/children/1') {
        return Promise.resolve({
          ok: true,
          headers: new Headers(),
          json: async () => ({ creatives: [{ id: 2 }] }),
        })
      }
      return Promise.resolve({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }] }),
      })
    })
    renderCreativeTree
      .mockImplementationOnce((element) => {
        element.innerHTML = `
          <creative-tree-row creative-id="1" has-children></creative-tree-row>
          <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
        `
      })
      .mockImplementationOnce((element) => {
        element.innerHTML = '<creative-tree-row creative-id="2"></creative-tree-row>'
        const row = element.querySelector('creative-tree-row')
        row.updateComplete = new Promise((resolve) => {
          finishChildUpdate = () => {
            row.innerHTML = cronTask('Server child message')
            row.querySelector('[data-cron-key]').dataset.cronKey = 'creative-2'
            resolve(true)
          }
        })
      })

    controller.load({ preserveView: true })
    await flush()
    await flush()

    expect(container.querySelector('textarea')).toBeNull()
    expect(controller._pendingCronMessageDrafts).toEqual(new Map([
      ['creative-2', 'Half-typed child message'],
    ]))

    finishChildUpdate()
    await flush()

    const input = container.querySelector('textarea')
    expect(input.value).toBe('Half-typed child message')
    expect(input.dataset.cronSavedMessage).toBe('Server child message')
    expect(controller._pendingCronMessageDrafts).toBeNull()
    application.stop()
  })

  test('keeps deferred branch drafts when a newer preserved load starts', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    container.querySelector('textarea').value = 'New root draft'
    controller._pendingCronMessageDrafts = new Map([
      ['creative-2', 'Deferred child draft'],
    ])
    global.fetch = jest.fn(() => new Promise(() => {}))

    controller.load({ preserveView: true })

    expect(controller._pendingCronMessageDrafts).toEqual(new Map([
      ['creative-2', 'Deferred child draft'],
      ['creative-1', 'New root draft'],
    ]))
    controller.stopAnimation()
    application.stop()
  })

  test('uses the refreshed cron message when the local message is clean', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = cronRow('Server message')
    })

    controller.load({ preserveView: true })
    await flush()
    await flush()

    expect(container.querySelector('textarea').value).toBe('Server message')
    application.stop()
  })

  test('does not restore a dirty cron message after edit access is lost', async () => {
    const { container, application, controller } = await installCachedTree(cronRow('Saved message'))
    container.querySelector('textarea').value = 'Half-typed message'
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = cronRow('Server message', { editable: false })
    })

    controller.load({ preserveView: true })
    await flush()
    await flush()

    expect(container.querySelector('textarea')).toBeNull()
    expect(container.querySelector('.cron-task-message').textContent).toBe('Server message')
    application.stop()
  })
})

describe('CreativesTreeController Chats pagination (load more)', () => {
  let originalFetch
  let originalIO

  class MockIntersectionObserver {
    constructor(callback) {
      this.callback = callback
      MockIntersectionObserver.instances.push(this)
    }
    observe(el) { this.observed = el }
    disconnect() { this.disconnected = true }
    triggerIntersect() { this.callback([{ isIntersecting: true }]) }
  }

  beforeEach(() => {
    originalFetch = global.fetch
    originalIO = global.IntersectionObserver
    MockIntersectionObserver.instances = []
    global.IntersectionObserver = MockIntersectionObserver
    appendCreativeNodes.mockClear()
  })

  afterEach(() => {
    global.fetch = originalFetch
    global.IntersectionObserver = originalIO
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('observes a sentinel only when the response carries has_more pagination', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
    })

    const { container, application } = installController()
    await flush()
    await flush()

    expect(MockIntersectionObserver.instances).toHaveLength(1)
    expect(container.querySelector('.creative-chats-load-sentinel')).not.toBeNull()

    application.stop()
  })

  test('does NOT set up pagination for a plain tree response (no pagination key)', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [{ id: 1 }] }),
    })

    const { container, application } = installController()
    await flush()
    await flush()

    expect(MockIntersectionObserver.instances).toHaveLength(0)
    expect(container.querySelector('.creative-chats-load-sentinel')).toBeNull()

    application.stop()
  })

  test('fetches the next page and appends rows when the sentinel intersects', async () => {
    const page2Nodes = [{ id: 2 }, { id: 3 }]
    global.fetch = jest
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: page2Nodes, pagination: { has_more: false, next_page: null } }),
      })

    const { application } = installController()
    await flush()
    await flush()

    const observer = MockIntersectionObserver.instances[0]
    observer.triggerIntersect()
    await flush()
    await flush()

    const secondCallUrl = global.fetch.mock.calls[1][0]
    expect(secondCallUrl).toContain('page=2')
    expect(appendCreativeNodes).toHaveBeenCalledTimes(1)
    expect(appendCreativeNodes.mock.calls[0][1]).toEqual(page2Nodes)
    // has_more:false on page 2 tears the observer down.
    expect(observer.disconnected).toBe(true)

    application.stop()
  })

  test('restores a deferred cron draft when its paginated row is appended', async () => {
    const page2Nodes = [{ id: 2 }]
    global.fetch = jest
      .fn()
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: page2Nodes, pagination: { has_more: false, next_page: null } }),
      })
    renderCreativeTree.mockImplementationOnce((container) => {
      container.innerHTML = '<creative-tree-row creative-id="1"></creative-tree-row>'
    })
    appendCreativeNodes.mockImplementationOnce((container) => {
      const row = document.createElement('creative-tree-row')
      row.setAttribute('creative-id', '2')
      row.innerHTML = `
        <span data-cron-key="creative-2">
          <textarea data-cron-badge-target="messageInput"
                    data-cron-saved-message="Server message">Server message</textarea>
        </span>
      `
      row.updateComplete = Promise.resolve(true)
      container.appendChild(row)
    })

    const { container, application } = installController()
    await flush()
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller._pendingCronMessageDrafts = new Map([
      ['creative-2', 'Half-typed page 2 message'],
    ])

    MockIntersectionObserver.instances[0].triggerIntersect()
    await flush()
    await flush()

    const input = container.querySelector('textarea')
    expect(input.value).toBe('Half-typed page 2 message')
    expect(input.dataset.cronSavedMessage).toBe('Server message')
    expect(controller._pendingCronMessageDrafts).toBeNull()
    application.stop()
  })

  test('drops a stale load-more response that resolves after a fresh load', async () => {
    let resolvePage2
    const page2Nodes = [{ id: 2 }, { id: 3 }]
    global.fetch = jest
      .fn()
      // initial page-1 (Chats filter, has more)
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })
      // page-2 stays pending until we resolve it manually
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolvePage2 = () =>
              resolve({
                ok: true,
                json: async () => ({ creatives: page2Nodes, pagination: { has_more: true, next_page: 3 } }),
              })
          })
      )
      // the fresh load() re-renders a different (non-paginated) view
      .mockResolvedValueOnce({
        ok: true,
        json: async () => ({ creatives: [{ id: 99 }] }),
      })

    const { container, application } = installController()
    await flush()
    await flush()

    // Sentinel intersects -> page-2 fetch kicks off but stays pending.
    MockIntersectionObserver.instances[0].triggerIntersect()
    await flush()

    // A fresh load happens before page 2 resolves (filter change, sync refetch,
    // archive toggle). load() tears down pagination and aborts the in-flight
    // load-more.
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.load()
    await flush()
    await flush()

    // The stale page-2 response finally arrives. It must NOT be appended into
    // the freshly rendered view.
    resolvePage2()
    await flush()
    await flush()

    expect(appendCreativeNodes).not.toHaveBeenCalled()

    application.stop()
  })

  // Deleting every row that is currently on screen does not mean the feed is
  // empty when further pages are still queued behind the sentinel. Restoring the
  // placeholder there both lies and outlives the append, leaving "No creatives
  // found." sitting above the rows the next page brings in.
  describe('empty-state placeholder vs. queued pages', () => {
    const installEmptyStateTemplate = () => {
      const template = document.createElement('template')
      template.id = 'creatives-empty-state-template'
      template.innerHTML = '<p data-creatives-empty-state>No creatives found.</p>'
      document.body.appendChild(template)
      return template
    }

    test('suppresses the placeholder while the feed has more pages queued', async () => {
      installEmptyStateTemplate()
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })

      const { container, application } = installController()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(true)

      // The user batch-deletes every rendered row; removeTreeElement asks for the
      // placeholder back.
      restoreTreeEmptyState(container)

      expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()

      application.stop()
    })

    test('restores the placeholder once the last page lands and nothing is left', async () => {
      installEmptyStateTemplate()
      global.fetch = jest
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [], pagination: { has_more: false, next_page: null } }),
        })

      const { container, application } = installController()
      await flush()
      await flush()

      restoreTreeEmptyState(container)
      expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()

      MockIntersectionObserver.instances[0].triggerIntersect()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(false)
      const placeholder = container.querySelector('[data-creatives-empty-state]')
      expect(placeholder).not.toBeNull()
      expect(placeholder.hidden).toBe(false)

      application.stop()
    })

    test('hides a placeholder that is on screen when the next page is appended', async () => {
      installEmptyStateTemplate()
      global.fetch = jest
        .fn()
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
        })
        .mockResolvedValueOnce({
          ok: true,
          json: async () => ({ creatives: [{ id: 2 }], pagination: { has_more: true, next_page: 3 } }),
        })

      const { container, application } = installController()
      await flush()
      await flush()

      // Belt and braces: a placeholder that got in anyway (a path that predates
      // the pending marker) must not survive the append.
      const stray = document.createElement('p')
      stray.setAttribute('data-creatives-empty-state', '')
      container.appendChild(stray)

      MockIntersectionObserver.instances[0].triggerIntersect()
      await flush()
      await flush()

      expect(appendCreativeNodes).toHaveBeenCalledTimes(1)
      expect(stray.hidden).toBe(true)

      application.stop()
    })

    test('clears the pending marker when a fresh load tears pagination down', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 1 }], pagination: { has_more: true, next_page: 2 } }),
      })

      const { container, application } = installController()
      await flush()
      await flush()
      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(true)

      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        json: async () => ({ creatives: [{ id: 9 }] }),
      })
      application.getControllerForElementAndIdentifier(container, 'creatives--tree').load()
      await flush()
      await flush()

      expect(container.hasAttribute('data-creatives-pagination-pending')).toBe(false)

      application.stop()
    })
  })
})

describe('CreativesTreeController error state vs genuine-empty state', () => {
  let originalFetch

  const installControllerWithStates = () => {
    // Mirrors index.html.erb: the actionable empty state lives in the server-rendered
    // <template> that showEmptyState() clones, while the load-error fallback is a bare
    // translated sentence the controller wraps in a <p> itself.
    const template = document.createElement('template')
    template.id = 'creatives-empty-state-template'
    template.innerHTML =
      '<div data-creatives-empty-state><div class="creative-empty-state">' +
      '<button class="new-root-creative-btn">Add</button></div></div>'
    document.body.appendChild(template)

    const container = document.createElement('div')
    container.setAttribute('data-controller', 'creatives--tree')
    container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
    container.setAttribute('data-creatives--tree-loading-text-value', 'Loading creatives')
    container.setAttribute(
      'data-creatives--tree-error-text-value',
      'Could not load the creative tree.'
    )
    document.body.appendChild(container)

    const application = Application.start()
    application.register('creatives--tree', TreeController)

    return { container, application }
  }

  beforeEach(() => {
    originalFetch = global.fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('a non-2xx response renders the distinct error state, not the actionable empty-state CTAs', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockResolvedValue({
      ok: false,
      status: 500,
      json: async () => ({}),
    })

    const { container, application } = installControllerWithStates()
    await flush()
    await flush()
    await flush()

    expect(container.dataset.loadState).toBe('error')
    expect(container.querySelector('.creative-tree-error')).not.toBeNull()
    expect(container.querySelector('.creative-empty-state')).toBeNull()
    expect(container.querySelector('.new-root-creative-btn')).toBeNull()

    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ creatives: [] }) })
    controller.load()
    expect(container.dataset.loadState).toBeUndefined()
    expect(container.dataset.loaded).toBeUndefined()
    await flush()
    await flush()
    expect(container.dataset.loadState).toBe('success')
    expect(container.querySelector('.new-root-creative-btn')).not.toBeNull()

    application.stop()
  })

  test('a JSON parse failure renders the distinct error state, not the actionable empty-state CTAs', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => {
        throw new SyntaxError('Unexpected token in JSON')
      },
    })

    const { container, application } = installControllerWithStates()
    await flush()
    await flush()
    await flush()

    expect(container.dataset.loadState).toBe('error')
    expect(container.querySelector('.creative-tree-error')).not.toBeNull()
    expect(container.querySelector('.creative-empty-state')).toBeNull()
    expect(container.querySelector('.new-root-creative-btn')).toBeNull()

    application.stop()
  })

  test('the error fallback renders its value as text, never as markup', async () => {
    jest.spyOn(console, 'error').mockImplementation(() => {})
    global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 500, json: async () => ({}) })

    const { container, application } = installControllerWithStates()
    container.setAttribute(
      'data-creatives--tree-error-text-value',
      '<img src=x onerror="window.__xss = true">'
    )
    await flush()
    await flush()
    await flush()

    const message = container.querySelector('.creative-tree-error')
    expect(message).not.toBeNull()
    // Parsed as markup this would be an <img>; as text it is just the literal string.
    expect(message.querySelector('img')).toBeNull()
    expect(message.textContent).toBe('<img src=x onerror="window.__xss = true">')

    application.stop()
  })

  test('a genuinely empty tree (successful response, zero creatives) still shows the actionable empty state', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({ creatives: [] }),
    })

    const { container, application } = installControllerWithStates()
    await flush()
    await flush()

    expect(container.querySelector('.new-root-creative-btn')).not.toBeNull()
    expect(container.dataset.loadState).toBe('success')
    expect(container.querySelector('.creative-tree-error')).toBeNull()

    application.stop()
  })
})

// The empty state used to be server-rendered inside #creatives, so the browser
// painted "No sub-creatives yet" the moment the HTML landed — before Stimulus had
// booted, let alone before the tree fetch had confirmed anything. index.html.erb
// now renders the loading placeholder there instead, and the controller adopts
// that node rather than replacing it.
describe('CreativesTreeController server-rendered loading placeholder', () => {
  let originalFetch

  const SERVER_PLACEHOLDER_HTML =
    '<div class="creative-tree-loading-placeholder" data-creatives-tree-loading role="status"' +
    ' aria-live="polite" aria-label="크리에이티브를 불러오는 중">' +
    '<span class="creative-loading-indicator" aria-hidden="true">' +
    '<span class="creative-loading-dot">.</span>' +
    '<span class="creative-loading-dot">.</span>' +
    '<span class="creative-loading-dot">.</span>' +
    '</span></div>'

  const installWithServerPlaceholder = ({ placeholder = true } = {}) => {
    const template = document.createElement('template')
    template.id = 'creatives-empty-state-template'
    template.innerHTML =
      '<div data-creatives-empty-state><div class="creative-empty-state">' +
      '<button class="new-root-creative-btn">Add</button></div></div>'
    document.body.appendChild(template)

    const container = document.createElement('div')
    container.setAttribute('data-controller', 'creatives--tree')
    container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
    container.setAttribute('data-creatives--tree-loading-text-value', '크리에이티브를 불러오는 중')
    if (placeholder) container.innerHTML = SERVER_PLACEHOLDER_HTML
    document.body.appendChild(container)

    const serverNode = container.querySelector('[data-creatives-tree-loading]')

    const application = Application.start()
    application.register('creatives--tree', TreeController)

    return { container, application, serverNode }
  }

  beforeEach(() => {
    originalFetch = global.fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('adopts the server-rendered placeholder instead of rebuilding it', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const { container, application, serverNode } = installWithServerPlaceholder()
    await flush()

    const live = container.querySelector('[data-creatives-tree-loading]')
    // Same node, still attached: rebuilding would blank the container for a frame,
    // which is precisely the flicker this arrangement removes.
    expect(live).toBe(serverNode)
    expect(container.children).toHaveLength(1)

    resolveFetch({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })

  test('does not paint the empty state before the fetch resolves', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const { container, application } = installWithServerPlaceholder()
    await flush()

    expect(container.querySelector('[data-creatives-empty-state]')).toBeNull()
    expect(container.querySelector('.new-root-creative-btn')).toBeNull()
    expect(container.querySelector('[data-creatives-tree-loading]')).not.toBeNull()

    resolveFetch({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })

  test('swaps the placeholder for the empty state only once zero rows are confirmed', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ creatives: [] }) })

    const { container, application } = installWithServerPlaceholder()
    await flush()
    await flush()

    expect(container.querySelector('[data-creatives-tree-loading]')).toBeNull()
    expect(container.querySelector('.new-root-creative-btn')).not.toBeNull()

    application.stop()
  })

  test('re-attaches the adopted placeholder on a later reload', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ creatives: [] }) })

    const { container, application, serverNode } = installWithServerPlaceholder()
    await flush()
    await flush()
    expect(container.querySelector('[data-creatives-tree-loading]')).toBeNull()

    let resolveSecond
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveSecond = resolve }))
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.load()

    expect(container.querySelector('[data-creatives-tree-loading]')).toBe(serverNode)
    expect(container.querySelector('.new-root-creative-btn')).toBeNull()

    resolveSecond({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })

  test('builds its own placeholder when the container has none, labelled from i18n', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const { container, application } = installWithServerPlaceholder({ placeholder: false })
    await flush()

    const built = container.querySelector('[data-creatives-tree-loading]')
    expect(built).not.toBeNull()
    expect(built.getAttribute('aria-label')).toBe('크리에이티브를 불러오는 중')
    expect(built.querySelectorAll('.creative-loading-dot')).toHaveLength(3)

    resolveFetch({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })

  test('requires a translated label when no server placeholder is available', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const { container, application } = installWithServerPlaceholder({ placeholder: false })
    await flush()
    container.removeAttribute('data-creatives--tree-loading-text-value')
    container.replaceChildren()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.loadingIndicator = null
    expect(() => controller.showLoadingIndicator()).toThrow(
      'creatives--tree requires a translated loadingText value when no server loading placeholder is present',
    )
    expect(container.querySelector('[data-creatives-tree-loading]')).toBeNull()

    resolveFetch({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })

  test('never adopts the load-more indicator as the tree placeholder', async () => {
    let resolveFetch
    global.fetch = jest.fn(() => new Promise((resolve) => { resolveFetch = resolve }))

    const { container, application } = installWithServerPlaceholder({ placeholder: false })
    await flush()
    // The paginated "Chats" feed appends its own .creative-tree-loading-placeholder;
    // it carries no data-creatives-tree-loading, so the selector must miss it.
    const loadMore = document.createElement('div')
    loadMore.className = 'creative-tree-loading-placeholder creative-chats-load-more'
    container.replaceChildren(loadMore)

    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    controller.loadingIndicator = null
    controller.showLoadingIndicator()

    expect(controller.loadingIndicator).not.toBe(loadMore)
    expect(container.contains(loadMore)).toBe(false)

    resolveFetch({ ok: true, json: async () => ({ creatives: [] }) })
    application.stop()
  })
})

// A reload replaces the whole container, so it takes the row an open editor is
// attached to out of the document — along with the unsaved draft inside it.
// Callers that reload in response to a request they fired earlier (archive /
// unarchive, delete-with-promoted-children) can land at any moment, including
// while the user has moved on and is editing a different row, so they go through
// requestReload() rather than load().
describe('CreativesTreeController requestReload', () => {
  let originalFetch

  // Stimulus connects asynchronously, so the controller instance only exists after
  // a turn of the real event loop — hence fake timers are switched on afterwards,
  // once connect()'s own initial load() is out of the way and can be stubbed out.
  const installConnected = async () => {
    const { container, application } = installController()
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    const load = jest.spyOn(controller, 'load').mockImplementation(() => {})
    jest.useFakeTimers()
    return { container, application, controller, load }
  }

  beforeEach(() => {
    originalFetch = global.fetch
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ creatives: [] }) })
  })

  afterEach(() => {
    jest.useRealTimers()
    global.fetch = originalFetch
    document.body.innerHTML = ''
    jest.restoreAllMocks()
  })

  test('reloads when no editor is open', async () => {
    const { application, controller, load } = await installConnected()

    controller.requestReload()
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledTimes(1)
    expect(load).toHaveBeenCalledWith({ preserveView: true })

    application.stop()
  })

  test('reloads with view preservation after a creative drop completes', async () => {
    const { application, controller, load } = await installConnected()

    controller._handleCreativeDrop()
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledWith({ preserveView: true })

    application.stop()
  })

  // The listener has to be removed by the same reference connect() registered,
  // or every reconnect leaves another tree reloading off a window-wide event.
  test('stops listening for drop completions once disconnected', async () => {
    const { application, controller } = await installConnected()
    const removeEventListener = jest.spyOn(window, 'removeEventListener')

    controller.disconnect()

    expect(removeEventListener).toHaveBeenCalledWith(
      'collavre:creative-drop-complete',
      controller._handleCreativeDrop
    )

    application.stop()
  })

  test('replaces the view outright when the caller does not ask to preserve it', async () => {
    const { application, controller, load } = await installConnected()

    controller.debouncedLoad()
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledWith({ preserveView: false })

    application.stop()
  })

  test('defers the reload while a row is being edited', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    controller.requestReload()
    jest.advanceTimersByTime(5000)

    expect(load).not.toHaveBeenCalled()

    application.stop()
  })

  test('runs the deferred reload once editing stops', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    controller.requestReload()
    jest.advanceTimersByTime(5000)
    expect(load).not.toHaveBeenCalled()

    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledTimes(1)

    application.stop()
  })

  test('does not reload on editing:stop when nothing was requested', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.advanceTimersByTime(5000)

    expect(load).not.toHaveBeenCalled()
    expect(controller).toBeDefined()

    application.stop()
  })

  // Switching rows is a stop immediately followed by a start, so a refetch drained
  // on the stop is still sitting in the 300ms debounce when the next row opens.
  // Checking _editing only at requestReload() time would let that timer fire and
  // re-render the tree out from under the newly opened editor, taking the row it
  // is attached to — and the draft inside it — out of the document.
  test('keeps the deferred reload pending across a row switch', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    controller.requestReload()

    // The switch: the outgoing row stops, the incoming row starts, both well
    // inside the debounce window.
    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    jest.advanceTimersByTime(5000)

    expect(load).not.toHaveBeenCalled()

    application.stop()
  })

  test('runs the reload once the row opened by the switch is closed', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    controller.requestReload()
    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    jest.advanceTimersByTime(5000)
    expect(load).not.toHaveBeenCalled()

    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.advanceTimersByTime(300)

    // Still exactly once: re-pending must not double-book the refetch.
    expect(load).toHaveBeenCalledTimes(1)

    application.stop()
  })

  // The re-check must not swallow the request: an editor that opens after the
  // timer has already fired is a separate matter, but one that opens during the
  // window has to leave the refetch queued rather than cancelled.
  test('re-arms the pending flag when the timer fires mid-edit', async () => {
    const { application, controller, load } = await installConnected()

    controller.requestReload()
    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    jest.advanceTimersByTime(300)
    expect(load).not.toHaveBeenCalled()

    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledTimes(1)

    application.stop()
  })

  test('keeps a pending reload held after editing stops until the operation finishes', async () => {
    const { application, controller, load } = await installConnected()

    document.dispatchEvent(new CustomEvent('creative-editing:start'))
    controller.beginReloadHold()
    controller.requestReload()
    document.dispatchEvent(new CustomEvent('creative-editing:stop'))
    jest.advanceTimersByTime(5000)

    expect(load).not.toHaveBeenCalled()

    controller.endReloadHold()
    jest.advanceTimersByTime(300)

    expect(load).toHaveBeenCalledTimes(1)

    application.stop()
  })

  test('coalesces reloads across overlapping operation holds', async () => {
    const { application, controller, load } = await installConnected()

    controller.beginReloadHold()
    controller.beginReloadHold()
    controller.requestReload()
    jest.advanceTimersByTime(5000)

    controller.endReloadHold()
    jest.advanceTimersByTime(5000)
    expect(load).not.toHaveBeenCalled()

    controller.endReloadHold()
    jest.advanceTimersByTime(300)
    expect(load).toHaveBeenCalledTimes(1)

    application.stop()
  })

  test('keeps captured view state when a preserved load supersedes an in-flight load', async () => {
    jest.useRealTimers()
    global.fetch = jest.fn(() => new Promise(() => {}))
    const container = document.createElement('div')
    container.setAttribute('data-controller', 'creatives--tree')
    container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
    container.setAttribute('data-creatives--tree-loading-text-value', 'Loading creatives')
    container.dataset.loaded = 'true'
    container.innerHTML = `
<creative-tree-row creative-id="1" expanded>
<button id="focused-control">Creative 1</button>
</creative-tree-row>
`
    document.body.appendChild(container)
    document.getElementById('focused-control').focus()
    const application = Application.start()
    application.register('creatives--tree', TreeController)
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')

    controller.load({ preserveView: true })
    const capturedState = controller._pendingViewState
    controller.load({ preserveView: true })

    expect(controller._pendingViewState).toBe(capturedState)
    expect(capturedState.expansion).toEqual([{ creativeId: '1', expanded: true }])
    expect(capturedState.focus).toEqual(expect.objectContaining({ creativeId: '1' }))

    controller.stopAnimation()
    application.stop()
  })

  test('keeps pending view state when a reload supersedes asynchronous restoration', async () => {
    jest.useRealTimers()
    let releaseChildren
    global.fetch = jest.fn((url) => {
      if (url === '/children/1') {
        return new Promise((resolve) => {
          releaseChildren = () => resolve({
            ok: true,
            headers: new Headers(),
            json: async () => ({ creatives: [{ id: 2 }] }),
          })
        })
      }
      return new Promise(() => {})
    })
    const container = document.createElement('div')
    container.setAttribute('data-controller', 'creatives--tree')
    container.setAttribute('data-creatives--tree-url-value', '/creatives?format=json&id=991')
    container.setAttribute('data-creatives--tree-loading-text-value', 'Loading creatives')
    container.dataset.loaded = 'true'
    document.body.appendChild(container)
    const application = Application.start()
    application.register('creatives--tree', TreeController)
    await flush()
    const controller = application.getControllerForElementAndIdentifier(container, 'creatives--tree')
    const viewState = {
      scrolling: document.documentElement,
      scrollTop: 120,
      focus: { creativeId: '1', controlId: 'focused-control', controlIndex: 0 },
      expansion: [{ creativeId: '1', expanded: true }],
    }
    controller._pendingViewState = viewState
    renderCreativeTree.mockImplementationOnce((element) => {
      element.innerHTML = `
        <creative-tree-row creative-id="1" has-children>
          <button id="focused-control">Creative 1</button>
        </creative-tree-row>
        <div id="creative-children-1" data-loaded="false" data-load-url="/children/1"></div>
      `
    })

    const restoration = controller.renderData({ creatives: [{ id: 1 }] })
    await flush()
    expect(controller._pendingViewState).toBe(viewState)

    controller.load({ preserveView: true })
    expect(controller._pendingViewState).toBe(viewState)
    releaseChildren()
    await restoration

    expect(controller._pendingViewState).toBe(viewState)

    controller.stopAnimation()
    application.stop()
  })
})
