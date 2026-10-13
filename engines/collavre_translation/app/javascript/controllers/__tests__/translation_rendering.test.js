/** @jest-environment jsdom */
import { Application } from '@hotwired/stimulus'
import { renderMarkdownInContainer } from 'collavre/lib/utils/markdown'
import Controller from '../comment_translation_controller'

test('list rendering preserves translated links and decorated tables', async () => {
  global.IntersectionObserver = class {
    observe() {}
    disconnect() {}
  }
  document.body.innerHTML = `<div class="comment-item"><div data-comment-target="content">Original</div>
    <div data-controller="comment-translation">
      <button data-comment-translation-target="toggle"></button>
      <div data-comment-translation-target="content"></div>
    </div></div>`
  const app = Application.start()
  app.register('comment-translation', Controller)
  await new Promise(resolve => setTimeout(resolve, 0))
  const controller = app.getControllerForElementAndIdentifier(document.querySelector('[data-controller]'), 'comment-translation')
  try {
    controller.show('[Translated link](https://example.com/destination)\n\n| Name |\n| --- |\n| Translated |')
    const content = controller.contentTarget
    const markup = content.innerHTML
    expect(content.dataset.rendered).toBe('true')
    renderMarkdownInContainer(document.body)
    expect(content.innerHTML).toBe(markup)
    expect(content.querySelector('a').href).toBe('https://example.com/destination')
    expect(content.querySelectorAll('.table-download-btn')).toHaveLength(2)
  } finally {
    controller.disconnect()
    app.stop()
    document.body.innerHTML = ''
  }
})
