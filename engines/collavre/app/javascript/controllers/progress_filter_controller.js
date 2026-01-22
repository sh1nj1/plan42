import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['button']

  apply(event) {
    event.preventDefault()
    const filter = event.params.filter ?? event.currentTarget.dataset.filter
    if (!filter) return

    const url = new URL(window.location.href)

    if (filter === 'comment') {
      if (url.searchParams.get('comment') === 'true') {
        url.searchParams.delete('comment')
      } else {
        url.searchParams.set('comment', 'true')
      }
    } else {
      url.searchParams.delete('min_progress')
      url.searchParams.delete('max_progress')

      if (filter === 'complete') {
        url.searchParams.set('min_progress', '1')
        url.searchParams.set('max_progress', '1')
      } else if (filter === 'incomplete') {
        url.searchParams.set('min_progress', '0')
        url.searchParams.set('max_progress', '0.99')
      }
    }

    const query = url.searchParams.toString()
    window.location.href = query ? `${url.pathname}?${query}` : url.pathname
  }
}
