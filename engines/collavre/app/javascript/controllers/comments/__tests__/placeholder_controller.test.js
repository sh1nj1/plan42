/**
 * @jest-environment jsdom
 */

import { Application } from '@hotwired/stimulus'
import PlaceholderController from '../placeholder_controller'

describe('PlaceholderController', () => {
  let application
  let list

  // The three empty-list states rendered by collavre/comments/_list.html.erb.
  const PLACEHOLDERS = [
    { id: 'no-comments', label: 'discovery cards' },
    { id: 'no-topic-comments', label: 'topic-empty notice' },
    { id: 'no-search-results', label: 'no-search-results notice' },
  ]

  const mount = (id) => {
    list = document.createElement('div')
    list.id = 'comments-list'
    list.innerHTML = `<div id="${id}" class="comments-placeholder" data-controller="comments--placeholder"><p>empty</p></div>`
    document.body.appendChild(list)
  }

  const appendComment = () => {
    const comment = document.createElement('div')
    comment.className = 'comment-item'
    list.appendChild(comment)
    return new Promise((r) => setTimeout(r, 0))
  }

  beforeEach(() => {
    application = Application.start()
    application.register('comments--placeholder', PlaceholderController)
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  PLACEHOLDERS.forEach(({ id, label }) => {
    test(`removes the ${label} when a comment is appended by a Turbo Stream`, async () => {
      // Comment#broadcast_create appends straight into #comments-list; nothing
      // on that path calls comments--form#removePlaceholder.
      mount(id)
      await new Promise((r) => setTimeout(r, 0))

      await appendComment()

      expect(list.querySelector(`#${id}`)).toBeNull()
    })
  })

  test('stays put when a non-comment node is appended to the list', async () => {
    mount('no-topic-comments')
    await new Promise((r) => setTimeout(r, 0))

    list.appendChild(document.createElement('div'))
    await new Promise((r) => setTimeout(r, 0))

    expect(list.querySelector('#no-topic-comments')).not.toBeNull()
  })

  test('stops observing once disconnected', async () => {
    mount('no-topic-comments')
    await new Promise((r) => setTimeout(r, 0))

    const placeholder = list.querySelector('#no-topic-comments')
    placeholder.removeAttribute('data-controller')
    await new Promise((r) => setTimeout(r, 0))

    await appendComment()

    // Detached from its controller, the element is left alone — proving the
    // observer is torn down rather than leaking past disconnect().
    expect(list.querySelector('#no-topic-comments')).not.toBeNull()
  })
})
