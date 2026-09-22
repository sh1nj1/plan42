import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import CreativeImageLightboxController from '../creative_image_lightbox_controller'
import ImageLightboxController from '../image_lightbox_controller'
import SelectModeController from '../creatives/select_mode_controller'

let application
const settle = () => new Promise((resolve) => setTimeout(resolve, 0))
const dialog = () => document.querySelector('.image-lightbox-dialog')
const click = (selector) => document.querySelector(selector).dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }))

beforeEach(async () => {
  globalThis.KeyboardEvent = window.KeyboardEvent
  globalThis.MouseEvent = window.MouseEvent
  window.HTMLDialogElement.prototype.showModal = function () { this.setAttribute('open', '') }
  window.HTMLDialogElement.prototype.close = function () { this.removeAttribute('open') }
  document.body.innerHTML = `
    <main data-controller="creative-image-lightbox" data-action="click->creative-image-lightbox#open:capture keydown->creative-image-lightbox#openFromKeyboard:capture"
      data-creative-image-lightbox-i18n-open-value="이미지 열기" data-creative-image-lightbox-i18n-close-value="닫기" data-creative-image-lightbox-i18n-zoom-in-value="확대">
      <creative-tree-row id="row"><div class="creative-content">
        <p id="text">Text</p><img id="first" src="/first.png" alt="First">
        <a href="/unwanted-navigation"><img id="second" src="/second.png" alt="Second"></a>
        <img id="empty" src=""><img id="missing">
      </div></creative-tree-row>
      <creative-tree-row><div class="creative-title-content"><img id="title" src="/title.png"></div></creative-tree-row>
      <div contenteditable="true"><div class="creative-content"><img id="editor" src="/editor.png"></div></div>
      <div class="inline-edit-form-shell"><div class="creative-content"><img id="form" src="/form.png"></div></div>
      <img id="avatar" src="/avatar.png">
    </main>`
  application = Application.start()
  application.register('creative-image-lightbox', CreativeImageLightboxController)
  application.register('image-lightbox', ImageLightboxController)
  await settle()
})

afterEach(async () => {
  document.body.innerHTML = ''
  await settle()
  application.stop()
  jest.restoreAllMocks()
})

test('opens the clicked image, blocks navigation and navigates across the creative list in DOM order', () => {
  const onClick = jest.fn()
  document.querySelector('#row').addEventListener('click', onClick)
  expect(click('#second')).toBe(false)
  expect(onClick).not.toHaveBeenCalled()
  expect(dialog().querySelector('img').src).toBe('http://localhost/second.png')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('2 / 3')
  click('.image-lightbox-next')
  expect(dialog().querySelector('img').src).toBe('http://localhost/title.png')
  click('.image-lightbox-next')
  expect(dialog().querySelector('img').src).toBe('http://localhost/first.png')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').src).toBe('http://localhost/title.png')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').src).toBe('http://localhost/second.png')
  expect(dialog().querySelector('.image-lightbox-delete').hidden).toBe(true)
  expect(dialog().querySelector('.image-lightbox-download-one').hidden).toBe(true)
  expect(dialog().querySelector('.image-lightbox-download-all')).toBeNull()
  expect(dialog().querySelector('.image-lightbox-close').title).toBe('닫기')
  expect(dialog().querySelector('.image-lightbox-zoom-in').title).toBe('확대')
})

test('opens title images and preserves zoom, keyboard navigation and close', () => {
  click('#title')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('3 / 3')
  expect(dialog().querySelector('.image-lightbox-next').style.visibility).toBe('visible')
  click('.image-lightbox-zoom-in')
  expect(dialog().querySelector('img').style.transform).toContain('scale(1.25)')
  click('.image-lightbox-close')
  expect(dialog()).toBeNull()
  click('#first')
  document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'ArrowRight' }))
  expect(dialog().querySelector('img').src).toBe('http://localhost/second.png')
  document.dispatchEvent(new window.KeyboardEvent('keydown', { key: 'Escape' }))
  expect(dialog()).toBeNull()
})

test('preserves image descriptions on every carousel entry and clears missing or empty alt text', () => {
  const description = 'Architecture: "Client" < API & 서버'
  document.querySelector('#second').alt = description
  document.querySelector('.creative-content').insertAdjacentHTML('beforeend', `
    <img src="/decorative.png" alt=""><img src="/undescribed.png">`)

  click('#second')
  expect(dialog().querySelector('img').alt).toBe(description)
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('First')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe(description)
})

test.each(['#text', '#empty', '#missing', '#editor', '#form', '#avatar'])('ignores %s', (selector) => {
  expect(click(selector)).toBe(true)
  expect(dialog()).toBeNull()
})

test('leaves explicit row select mode to the row selection handler', () => {
  document.querySelector('#row').selectMode = true
  click('#first')
  expect(dialog()).toBeNull()
})

test('toolbar selection selects the image row without opening the viewer, then restores viewing', async () => {
  const main = document.querySelector('main')
  main.dataset.controller += ' creatives--select-mode'
  main.insertAdjacentHTML('afterbegin', `
    <button id="select" data-action="creatives--select-mode#toggle">Select</button>`)
  const content = document.querySelector('#row .creative-content')
  content.classList.add('creative-row')
  content.setAttribute('data-creatives--select-mode-target', 'row')
  content.insertAdjacentHTML('afterbegin', `
    <input type="checkbox" class="select-creative-checkbox" data-creatives--select-mode-target="checkbox">`)
  application.register('creatives--select-mode', SelectModeController)
  await settle()

  click('#select')
  expect(document.querySelector('#row').selectMode).toBeUndefined()
  document.querySelector('#first').dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true, cancelable: true }))
  document.dispatchEvent(new window.MouseEvent('mouseup', { bubbles: true }))
  click('#first')
  expect(content.querySelector('input').checked).toBe(true)
  expect(content.classList.contains('selected')).toBe(true)
  expect(dialog()).toBeNull()
  click('#title')
  expect(dialog()).toBeNull()

  const onClick = jest.fn()
  content.addEventListener('click', onClick)
  expect(click('#second')).toBe(false)
  expect(onClick).toHaveBeenCalledTimes(1)
  expect(content.querySelector('input').checked).toBe(true)
  expect(dialog()).toBeNull()
  const onDocumentKeydown = jest.fn()
  document.addEventListener('keydown', onDocumentKeydown)
  try {
    for (const selector of ['#first', '#title', '.creative-content a']) {
      for (const key of ['Enter', ' ']) {
        expect(keydown(selector, key)).toBe(false)
        expect(onDocumentKeydown).not.toHaveBeenCalled()
        expect(dialog()).toBeNull()
        expect(content.querySelector('input').checked).toBe(true)
      }
    }
    expect(keydown('#first', 'Tab')).toBe(true)
    expect(onDocumentKeydown).toHaveBeenCalledTimes(1)
  } finally {
    document.removeEventListener('keydown', onDocumentKeydown)
  }

  click('#select')
  expect(content.querySelector('input').checked).toBe(false)
  click('#first')
  expect(dialog().querySelector('img').src).toBe('http://localhost/first.png')
})

test('opens images when the selection controller has not connected', () => {
  document.querySelector('main').dataset.controller += ' creatives--select-mode'
  click('#first')
  expect(dialog().querySelector('img').src).toBe('http://localhost/first.png')
})

test('uses fresh images after a streamed update and closes on disconnect', async () => {
  document.querySelector('.creative-content').innerHTML = '<img id="fresh" src="/fresh.png">'
  click('#fresh')
  expect(dialog().querySelector('img').src).toBe('http://localhost/fresh.png')
  document.querySelector('main').remove()
  await settle()
  expect(dialog()).toBeNull()
})

test('chat attachments retain their index, download and delete controls', async () => {
  document.body.insertAdjacentHTML('beforeend', `
    <div data-controller="image-lightbox" data-image-lightbox-download-all-url-value="/comments/1/download_images">
      <a id="chat-first" data-action="click->image-lightbox#open" data-image-lightbox-index-param="0" data-full-src="/chat-first.png"></a>
      <a id="chat-second" data-action="click->image-lightbox#open" data-image-lightbox-index-param="1" data-full-src="/chat-second.png"></a>
    </div>`)
  await settle()
  click('#chat-second')
  expect(dialog().querySelector('img').src).toBe('http://localhost/chat-second.png')
  expect(dialog().querySelector('img').alt).toBe('')
  expect(dialog().querySelector('.image-lightbox-delete').hidden).toBe(false)
  expect(dialog().querySelector('.image-lightbox-download-one').hidden).toBe(false)
  expect(dialog().querySelector('.image-lightbox-download-all')).not.toBeNull()
  jest.useFakeTimers()
  click('.image-lightbox-download-one')
  expect(document.querySelector('iframe').getAttribute('src')).toBe('/comments/1/download_images?index=1')
  jest.runOnlyPendingTimers()
  jest.useRealTimers()
})

const keydown = (selector, key) => document.querySelector(selector).dispatchEvent(
  new window.KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }))

test('makes non-linked list and title images accessible without duplicate link tab stops', () => {
  for (const selector of ['#first', '#title']) {
    const image = document.querySelector(selector)
    expect(image.tabIndex).toBe(0)
    expect(image.getAttribute('role')).toBe('button')
    expect(image.getAttribute('aria-haspopup')).toBe('dialog')
    image.focus()
    expect(document.activeElement).toBe(image)
  }
  expect(document.querySelector('#first').getAttribute('aria-label')).toBe('First')
  expect(document.querySelector('#title').getAttribute('aria-label')).toBe('이미지 열기')
  expect(document.querySelector('#second').hasAttribute('tabindex')).toBe(false)
  expect(document.querySelector('#second').closest('a').getAttribute('aria-haspopup')).toBe('dialog')
  for (const selector of ['#empty', '#missing', '#editor', '#form', '#avatar']) {
    expect(document.querySelector(selector).hasAttribute('tabindex')).toBe(false)
  }
})

test.each(['Enter', ' '])('opens a focused image with %s without triggering row editing', (key) => {
  const onKeydown = jest.fn()
  document.querySelector('#row').addEventListener('keydown', onKeydown)
  document.querySelector('#first').focus()
  expect(keydown('#first', key)).toBe(false)
  expect(onKeydown).not.toHaveBeenCalled()
  expect(dialog().querySelector('img').alt).toBe('First')
})

test('opens a linked image on the native keyboard click from its anchor', () => {
  expect(click('.creative-content a')).toBe(false)
  expect(dialog().querySelector('img').alt).toBe('Second')
})

test('ignores unrelated keys and ordinary text links', () => {
  expect(keydown('#first', 'Tab')).toBe(true)
  expect(keydown('#text', 'Enter')).toBe(true)
  document.querySelector('.creative-content').insertAdjacentHTML('beforeend', '<a id="text-link">Text link</a>')
  expect(click('#text-link')).toBe(true)
  expect(dialog()).toBeNull()
})

test('prepares streamed images and updated descriptions for keyboard activation', async () => {
  const content = document.querySelector('.creative-content')
  content.innerHTML = '<img id="fresh" src="/fresh.png" alt="Fresh">'
  await settle()
  expect(document.querySelector('#fresh').tabIndex).toBe(0)
  document.querySelector('#fresh').alt = 'Updated'
  await settle()
  expect(document.querySelector('#fresh').getAttribute('aria-label')).toBe('Updated')
  expect(keydown('#fresh', 'Enter')).toBe(false)
  expect(dialog().querySelector('img').alt).toBe('Updated')
})

test('preserves pointer navigation on the text portion of a mixed image link', () => {
  const link = document.querySelector('.creative-content a')
  link.href = '#original'
  link.insertAdjacentHTML('beforeend', '<span id="link-caption">Visit original</span>')
  expect(document.querySelector('#link-caption').dispatchEvent(
    new window.MouseEvent('click', { detail: 1, bubbles: true, cancelable: true }))).toBe(true)
  expect(dialog()).toBeNull()
})

test('preserves keyboard navigation on mixed image links', async () => {
  const link = document.querySelector('#second').closest('a')
  link.href = '#documentation'
  link.insertAdjacentHTML('beforeend', '<span>Documentation</span>')
  await settle()
  expect(keydown('.creative-content a', 'Enter')).toBe(true)
  expect(click('.creative-content a')).toBe(true)
  expect(dialog()).toBeNull()
  expect(link.hasAttribute('aria-haspopup')).toBe(false)
  expect(click('#second')).toBe(false)
  expect(dialog().querySelector('img').alt).toBe('Second')
})

test.each(['', null])('names otherwise unnamed image links with alt %s', async (alt) => {
  const image = document.querySelector('#second')
  if (alt === null) image.removeAttribute('alt')
  else image.alt = alt
  await settle()
  const link = image.closest('a')
  expect(link.getAttribute('aria-label')).toBe('이미지 열기')
  expect(link.getAttribute('aria-haspopup')).toBe('dialog')
  expect(click('.creative-content a')).toBe(false)
  expect(dialog()).not.toBeNull()
})

test.each([
  ['aria-label="Original image"', '<img src="/named.png" alt="">'],
  ['aria-labelledby="text"', '<img src="/named.png">'],
  ['title="Original image"', '<img src="/named.png">'],
  ['', '<img src="/named.png" alt="Description">'],
  ['', '<img src="/named.png"><span>Documentation</span>'],
  ['', '<img src="/named.png"><img src="/other.png" alt="Other description">']
])('preserves existing link names: %s %s', async (attributes, content) => {
  document.querySelector('.creative-content').insertAdjacentHTML('beforeend',
    `<a id="named-link" href="/original" ${attributes}>${content}</a>`)
  await settle()
  const link = document.querySelector('#named-link')
  expect(link.getAttribute('aria-label')).toBe(attributes.startsWith('aria-label=') ? 'Original image' : null)
})

test.each(['alt', 'caption'])('releases generated link labels when %s arrives and restores them when removed', async (source) => {
  const image = document.querySelector('#second')
  const link = image.closest('a')
  image.alt = ''
  await settle()
  expect(link.getAttribute('aria-label')).toBe('이미지 열기')

  if (source === 'alt') image.alt = 'Updated description'
  else link.insertAdjacentHTML('beforeend', '<span>Documentation</span>')
  await settle()
  expect(link.hasAttribute('aria-label')).toBe(false)
  expect(link.getAttribute('aria-haspopup')).toBe(source === 'alt' ? 'dialog' : null)

  if (source === 'alt') image.alt = ''
  else link.querySelector('span').remove()
  await settle()
  expect(link.getAttribute('aria-label')).toBe('이미지 열기')
  expect(link.getAttribute('aria-haspopup')).toBe('dialog')
})

test('preserves an authored label that replaces the generated fallback', async () => {
  const image = document.querySelector('#second')
  const link = image.closest('a')
  image.alt = ''
  await settle()
  expect(link.getAttribute('aria-label')).toBe('이미지 열기')
  link.setAttribute('aria-label', 'Author supplied name')
  image.alt = 'Updated description'
  await settle()
  expect(link.getAttribute('aria-label')).toBe('Author supplied name')
  link.insertAdjacentHTML('beforeend', '<span>Documentation</span>')
  await settle()
  expect(link.getAttribute('aria-label')).toBe('Author supplied name')
})

test('keeps generated label ownership across controller reconnection', async () => {
  const image = document.querySelector('#second')
  const link = image.closest('a')
  const main = document.querySelector('main')
  image.alt = ''
  await settle()
  main.remove()
  await settle()
  document.body.append(main)
  await settle()
  expect(link.getAttribute('aria-label')).toBe('이미지 열기')
  image.alt = 'Description after reconnect'
  await settle()
  expect(link.hasAttribute('aria-label')).toBe(false)
})

test('makes an image keyboard accessible when its source arrives later', async () => {
  document.querySelector('#missing').src = '/loaded.png'
  await settle()
  document.querySelector('#missing').focus()
  expect(document.activeElement.id).toBe('missing')
  expect(keydown('#missing', 'Enter')).toBe(false)
  expect(dialog().querySelector('img').src).toBe('http://localhost/loaded.png')
})

test('rebuilds the gallery across rows on each open and preserves duplicate image positions', () => {
  const titleRow = document.querySelector('#title').closest('creative-tree-row')
  titleRow.insertAdjacentHTML('afterend', `
    <creative-tree-row id="streamed"><div class="creative-content"><img id="duplicate" src="/first.png" alt="Duplicate"></div></creative-tree-row>`)
  click('#duplicate')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('4 / 4')
  expect(dialog().querySelector('img').alt).toBe('Duplicate')
  click('.image-lightbox-close')
  document.querySelector('#row').remove()
  titleRow.before(document.querySelector('#streamed'))
  click('#title')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('2 / 2')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('Duplicate')
})

test('excludes images outside the current list and editor images inside a creative', () => {
  document.body.insertAdjacentHTML('beforeend', '<div class="creative-content"><img src="/outside.png"></div>')
  document.querySelector('.creative-content').insertAdjacentHTML('beforeend', `
    <div contenteditable="true"><img src="/nested-editor.png"></div>
    <div class="inline-edit-form-shell"><img src="/nested-form.png"></div>`)
  click('#first')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('1 / 3')
})


test.each([
  ['collapsed subtree', '<div class="creative-children" data-expanded="false" style="display:none">'],
  ['row being edited', '<div class="creative-row" style="display:none">'],
  ['hidden ancestor', '<div hidden>']
])('excludes images inside a %s from the gallery', (_name, container) => {
  document.querySelector('main').insertAdjacentHTML('beforeend', `${container}
    <creative-tree-row><div class="creative-content"><img id="hidden-image" src="/hidden.png"></div></creative-tree-row>
  </div>`)
  expect(click('#hidden-image')).toBe(true)
  expect(dialog()).toBeNull()
  click('#title')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('3 / 3')
  click('.image-lightbox-next')
  expect(dialog().querySelector('img').alt).toBe('First')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').src).toBe('http://localhost/title.png')
})

test.each(['hidden', 'display'])('excludes an image directly hidden with %s', (mechanism) => {
  const image = document.querySelector('#second')
  if (mechanism === 'hidden') image.hidden = true
  else image.style.display = 'none'
  click('#title')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('2 / 2')
  click('.image-lightbox-prev')
  expect(dialog().querySelector('img').alt).toBe('First')
})

test('prepares collapsed images and rebuilds the gallery after expanding and collapsing loaded rows', async () => {
  document.querySelector('main').insertAdjacentHTML('beforeend', `
    <div id="children" class="creative-children" data-expanded="false" style="display:none">
      <creative-tree-row><div class="creative-content"><img id="child-image" src="/child.png" alt="Child"></div></creative-tree-row>
    </div>`)
  await settle()
  const children = document.querySelector('#children')
  const child = document.querySelector('#child-image')
  expect(child.tabIndex).toBe(0)
  expect(child.getAttribute('role')).toBe('button')
  expect(child.getAttribute('aria-haspopup')).toBe('dialog')
  expect(child.getAttribute('aria-label')).toBe('Child')

  children.style.display = ''
  children.dataset.expanded = 'true'
  child.focus()
  expect(document.activeElement).toBe(child)
  expect(keydown('#child-image', 'Enter')).toBe(false)
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('4 / 4')
  expect(dialog().querySelector('img').alt).toBe('Child')
  click('.image-lightbox-close')

  children.style.display = 'none'
  children.dataset.expanded = 'false'
  click('#title')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('3 / 3')
  click('.image-lightbox-close')
  children.style.display = ''
  children.dataset.expanded = 'true'
  expect(keydown('#child-image', ' ')).toBe(false)
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('4 / 4')
})
