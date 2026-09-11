import { jest } from '@jest/globals'
import { Application } from '@hotwired/stimulus'
import CreativeImageLightboxController from '../creative_image_lightbox_controller'
import ImageLightboxController from '../image_lightbox_controller'

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
    <main data-controller="creative-image-lightbox" data-action="click->creative-image-lightbox#open:capture"
      data-creative-image-lightbox-i18n-close-value="닫기" data-creative-image-lightbox-i18n-zoom-in-value="확대">
      <creative-tree-row id="row"><div class="creative-content">
        <p id="text">Text</p><img id="first" src="/first.png" alt="First">
        <a href="/unwanted-navigation"><img id="second" src="/second.png" alt="Second"></a>
        <img id="empty" src=""><img id="missing">
      </div></creative-tree-row>
      <creative-tree-row><div class="creative-title-content"><img id="title" src="/title.png"></div></creative-tree-row>
      <div contenteditable="true"><div class="creative-content"><img id="editor" src="/editor.png"></div></div>
      <div class="inline-edit-form"><div class="creative-content"><img id="form" src="/form.png"></div></div>
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

test('opens the clicked image, blocks navigation and scopes the carousel to its creative', () => {
  const onClick = jest.fn()
  document.querySelector('#row').addEventListener('click', onClick)
  expect(click('#second')).toBe(false)
  expect(onClick).not.toHaveBeenCalled()
  expect(dialog().querySelector('img').src).toBe('http://localhost/second.png')
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('2 / 2')
  click('.image-lightbox-next')
  expect(dialog().querySelector('img').src).toBe('http://localhost/first.png')
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
  expect(dialog().querySelector('.image-lightbox-counter').textContent).toBe('1 / 1')
  expect(dialog().querySelector('.image-lightbox-next').style.visibility).toBe('hidden')
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

test.each(['#text', '#empty', '#missing', '#editor', '#form', '#avatar'])('ignores %s', (selector) => {
  expect(click(selector)).toBe(true)
  expect(dialog()).toBeNull()
})

test('leaves select mode to the row selection handler', () => {
  document.querySelector('#row').selectMode = true
  click('#first')
  expect(dialog()).toBeNull()
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
  expect(dialog().querySelector('.image-lightbox-delete').hidden).toBe(false)
  expect(dialog().querySelector('.image-lightbox-download-one').hidden).toBe(false)
  expect(dialog().querySelector('.image-lightbox-download-all')).not.toBeNull()
  jest.useFakeTimers()
  click('.image-lightbox-download-one')
  expect(document.querySelector('iframe').getAttribute('src')).toBe('/comments/1/download_images?index=1')
  jest.runOnlyPendingTimers()
  jest.useRealTimers()
})
