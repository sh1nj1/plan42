import { Controller } from '@hotwired/stimulus'
import {
  applyFilterParam,
  buildFilterUrl,
  syncFilterButtons,
  visitFilterUrl
} from '../lib/utils/filter_navigation'

export default class extends Controller {
  static targets = ['button']
  static values = { indexPath: String, onIndex: Boolean }

  apply(event) {
    event.preventDefault()
    const filter = event.params.filter ?? event.currentTarget.dataset.filter
    if (!filter) return

    const url = buildFilterUrl(
      { indexPath: this.indexPathValue, onIndex: this.onIndexValue },
      (params) => applyFilterParam(params, filter)
    )

    if (visitFilterUrl(url)) syncFilterButtons(url)
  }
}
