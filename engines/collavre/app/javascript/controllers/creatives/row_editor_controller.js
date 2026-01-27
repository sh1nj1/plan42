import { Controller } from '@hotwired/stimulus'
import { initializeCreativeRowEditor } from '../../modules/creative_row_editor'

export default class extends Controller {
  connect() {
    initializeCreativeRowEditor()
  }
}
