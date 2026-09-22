import { jest } from '@jest/globals'

const notifyPopupOpen = jest.fn()
const onOtherPopupOpen = jest.fn()
jest.unstable_mockModule('collavre/lib/gnb_popup_manager', () => ({
  notifyPopupOpen, onOtherPopupOpen
}), { virtual: true })

await import('../plans_menu.js')

function renderMenu() {
  document.body.innerHTML = `
    <button class="plans-menu-btn"><span>Plans</span></button>
    <button class="plans-menu-btn" id="mobile-plans">Plans</button>
    <div id="plans-list-area" style="display:none" data-plans-url="/mounted/plans.json">
      <div id="plans-timeline"></div>
    </div>`
}

function navigate() {
  document.dispatchEvent(new window.Event('turbo:load'))
}

async function click(selector = '.plans-menu-btn span') {
  document.querySelector(selector).click()
  await new Promise(resolve => setTimeout(resolve, 0))
}

beforeEach(() => {
  renderMenu()
  global.fetch = jest.fn().mockResolvedValue({ json: async () => [{ id: 1 }] })
  window.initPlansTimeline = jest.fn()
  notifyPopupOpen.mockClear()
})

test('opens once after repeated navigation with the GNB preserved', async () => {
  navigate()
  navigate()
  await click()
  expect(document.getElementById('plans-list-area').style.display).toBe('block')
  expect(fetch).toHaveBeenCalledTimes(1)
  expect(fetch).toHaveBeenCalledWith('/mounted/plans.json')
  expect(notifyPopupOpen).toHaveBeenCalledTimes(1)
  expect(window.initPlansTimeline).toHaveBeenCalledWith(document.getElementById('plans-timeline'))
  expect(document.getElementById('plans-timeline').dataset.plans).toBe('[{"id":1}]')
})

test('desktop and mobile toggle the same panel and reuse loaded plans', async () => {
  navigate()
  await click()
  await click('#mobile-plans')
  expect(document.getElementById('plans-list-area').style.display).toBe('none')
  await click('#mobile-plans')
  expect(document.getElementById('plans-list-area').style.display).toBe('block')
  expect(fetch).toHaveBeenCalledTimes(1)
})

test('loads the new panel after full page replacement', async () => {
  navigate()
  await click()
  renderMenu()
  navigate()
  await click()
  expect(document.getElementById('plans-list-area').style.display).toBe('block')
  expect(fetch).toHaveBeenCalledTimes(2)
})

test('other popups close the current panel after replacement', async () => {
  navigate()
  renderMenu()
  navigate()
  await click()
  onOtherPopupOpen.mock.calls.at(-1)[1]()
  expect(document.getElementById('plans-list-area').style.display).toBe('none')
  document.body.innerHTML = ''
  expect(() => onOtherPopupOpen.mock.calls.at(-1)[1]()).not.toThrow()
})

test('ignores unrelated clicks and pages without a plans panel', async () => {
  navigate()
  await click('#plans-timeline')
  document.getElementById('plans-list-area').remove()
  await click()
  expect(fetch).not.toHaveBeenCalled()
})

test('supports the fallback endpoint and an absent timeline', async () => {
  document.getElementById('plans-list-area').removeAttribute('data-plans-url')
  document.getElementById('plans-timeline').remove()
  navigate()
  await click()
  expect(fetch).toHaveBeenCalledWith('/plans.json')
  expect(window.initPlansTimeline).not.toHaveBeenCalled()
})

test('stores plans when the timeline initializer is unavailable', async () => {
  delete window.initPlansTimeline
  navigate()
  await click()
  expect(document.getElementById('plans-timeline').dataset.plans).toBe('[{"id":1}]')
})
