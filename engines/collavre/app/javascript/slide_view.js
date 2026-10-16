// Entry point for slide view
import './modules/slide_view'
import './lib/ppt_formatting'

import './modules/ppt_viewer'

import { Application } from '@hotwired/stimulus'
import DocumentPreviewController from './controllers/document_preview_controller'

const application = Application.start()
application.register('document-preview', DocumentPreviewController)
