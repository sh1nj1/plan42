/**
 * @jest-environment jsdom
 */
import { Application } from '@hotwired/stimulus'

const { default: TabsController } = await import('../tabs_controller')

describe('TabsController', () => {
  let application

  // jsdom's window.location is unforgeable, so drive it through history.
  function setLocation(href, state = {}) {
    window.history.replaceState(state, '', href)
  }

  async function mount({ activeTab = 'profile' } = {}) {
    document.body.innerHTML = `
      <div data-controller="tabs" data-tabs-active-tab-value="${activeTab}">
        <div class="tab-list">
          <button class="tab-button" data-action="click->tabs#switch"
                  data-tabs-tab-param="profile" data-tabs-target="tabButton">Profile</button>
          <button class="tab-button" data-action="click->tabs#switch"
                  data-tabs-tab-param="contacts" data-tabs-target="tabButton">User management</button>
        </div>
        <div class="tab-panels">
          <section class="tab-panel" data-tabs-target="panel" data-tab-name="profile"></section>
          <section class="tab-panel" data-tabs-target="panel" data-tab-name="contacts"></section>
        </div>
      </div>
    `

    application = Application.start()
    application.register('tabs', TabsController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  function clickTab(tab) {
    document.querySelector(`[data-tabs-tab-param="${tab}"]`).click()
  }

  function panel(name) {
    return document.querySelector(`[data-tab-name="${name}"]`)
  }

  beforeEach(() => {
    setLocation('http://localhost/users/1')
  })

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
  })

  test('shows the server-rendered tab on connect', async () => {
    await mount({ activeTab: 'contacts' })

    expect(panel('contacts').classList.contains('active')).toBe(true)
    expect(panel('profile').classList.contains('active')).toBe(false)
  })

  test('defaults to the profile tab when none is set', async () => {
    document.body.innerHTML = `
      <div data-controller="tabs">
        <div class="tab-panels">
          <section class="tab-panel" data-tabs-target="panel" data-tab-name="profile"></section>
          <section class="tab-panel" data-tabs-target="panel" data-tab-name="contacts"></section>
        </div>
      </div>
    `
    application = Application.start()
    application.register('tabs', TabsController)
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(panel('profile').classList.contains('active')).toBe(true)
  })

  test('switching a tab activates its panel and button', async () => {
    await mount()

    clickTab('contacts')

    expect(panel('contacts').classList.contains('active')).toBe(true)
    expect(document.querySelector('[data-tabs-tab-param="contacts"]').classList.contains('active')).toBe(true)
    expect(document.querySelector('[data-tabs-tab-param="profile"]').classList.contains('active')).toBe(false)
  })

  test('switching a tab records it in the query string', async () => {
    await mount()

    clickTab('contacts')

    expect(window.location.search).toBe('?tab=contacts')
  })

  test('leaving the contacts tab drops its pagination cursor', async () => {
    setLocation('http://localhost/users/1?tab=contacts&contact_page=3')
    await mount({ activeTab: 'contacts' })

    clickTab('profile')

    expect(window.location.search).toBe('?tab=profile')
  })

  test('staying on the contacts tab keeps its pagination cursor', async () => {
    setLocation('http://localhost/users/1?tab=contacts&contact_page=3')
    await mount({ activeTab: 'contacts' })

    clickTab('contacts')

    expect(window.location.search).toBe('?tab=contacts&contact_page=3')
  })

  test('ignores a click that names no tab', async () => {
    await mount()
    const button = document.querySelector('[data-tabs-tab-param="contacts"]')
    delete button.dataset.tabsTabParam

    button.click()

    expect(panel('profile').classList.contains('active')).toBe(true)
    expect(window.location.search).toBe('')
  })

  // Turbo Drive only restores a history entry whose state still carries its
  // restorationIdentifier. Overwriting the state here left back navigation
  // changing the URL while the previous page stayed on screen — leaving the
  // AI agent edit form up after backing out of it.
  test('switching a tab keeps the Turbo history state intact', async () => {
    const turboState = { turbo: { restorationIdentifier: 'abc-123', restorationIndex: 4 } }
    setLocation('http://localhost/users/1', turboState)
    await mount()

    clickTab('contacts')

    expect(window.history.state).toEqual(turboState)
  })
})
