import { jest } from '@jest/globals'

const csrfFetch = jest.fn()
const alertDialog = jest.fn()
jest.unstable_mockModule('../../../lib/api/csrf_fetch', () => ({ default: csrfFetch }))
jest.unstable_mockModule('../../../lib/utils/dialog', () => ({ alertDialog }))
const ImportController = (await import('../import_controller')).default

describe('PowerPoint upload validation', () => {
  let controller

  beforeEach(() => {
    jest.useFakeTimers()
    csrfFetch.mockReset()
    alertDialog.mockReset()
    controller = Object.create(ImportController.prototype)
    Object.defineProperties(controller, {
      onlyMarkdownValue: { value: 'Choose Markdown or PPTX' },
      uploadingValue: { value: 'Uploading' },
      failedValue: { value: 'Failed' },
      parentIdValue: { value: '123' },
    })
    controller.showProgress = jest.fn()
    controller.hideProgress = jest.fn()
    csrfFetch.mockResolvedValue({ json: async () => ({ error: 'Invalid file type' }) })
  })

  afterEach(() => {
    jest.clearAllTimers()
    jest.useRealTimers()
  })

  test('accepts PPTX case-insensitively and sends it to the import endpoint', async () => {
    const file = new File(['pptx'], 'Slides.PPTX')
    await controller.handleFile(file)
    expect(csrfFetch).toHaveBeenCalledWith('/creative_imports', expect.objectContaining({ method: 'POST' }))
    const body = csrfFetch.mock.calls[0][1].body
    expect(body.get('markdown').name).toBe('Slides.PPTX')
    expect(body.get('parent_id')).toBe('123')
    expect(alertDialog).not.toHaveBeenCalled()
  })

  test('rejects legacy PPT before any upload', async () => {
    await controller.handleFile(new File(['ppt'], 'Slides.ppt'))
    expect(alertDialog).toHaveBeenCalledWith('Choose Markdown or PPTX')
    expect(csrfFetch).not.toHaveBeenCalled()
  })
})
