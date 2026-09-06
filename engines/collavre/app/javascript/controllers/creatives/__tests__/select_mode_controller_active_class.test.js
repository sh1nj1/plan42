/**
 * @jest-environment jsdom
 *
 * Select mode is toggled from the toolbar long after the creative rows have
 * rendered, so rows cannot learn about it from their own attributes. The
 * controller publishes it as `.select-mode-active` on its container, which
 * creative-tree-row checks before it temporarily clears the draggable
 * attribute for text selection — that attribute is what handleRowMouseDown
 * reads to tell a bundle drag from a selection toggle.
 */
import { Application } from '@hotwired/stimulus'

const { default: SelectModeController } = await import('../select_mode_controller')

describe('SelectModeController select-mode-active class', () => {
  let application
  let element
  let toggleButton

  beforeEach(async () => {
    document.body.innerHTML = `
      <div data-controller="select-mode">
        <button type="button"
                data-select-mode-target="toggle"
                data-action="select-mode#toggle"
                data-select-text="Select"
                data-cancel-text="Cancel">Select</button>
        <div class="creative-row" data-select-mode-target="row">
          <input type="checkbox" class="select-creative-checkbox" data-select-mode-target="checkbox">
        </div>
      </div>
    `
    element = document.querySelector('[data-controller="select-mode"]')
    toggleButton = element.querySelector('[data-select-mode-target="toggle"]')

    application = Application.start()
    application.register('select-mode', SelectModeController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  })

  afterEach(() => {
    application.stop()
    document.body.innerHTML = ''
  })

  test('is absent until select mode is entered', () => {
    expect(element.classList.contains('select-mode-active')).toBe(false)
  })

  test('is added on toggle and removed on cancel', () => {
    toggleButton.click()
    expect(element.classList.contains('select-mode-active')).toBe(true)

    toggleButton.click()
    expect(element.classList.contains('select-mode-active')).toBe(false)
  })

  test('is cleared when the controller disconnects while active', async () => {
    toggleButton.click()
    expect(element.classList.contains('select-mode-active')).toBe(true)

    element.remove()
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(element.classList.contains('select-mode-active')).toBe(false)
  })

  test('an already-selected row still starts a bundle drag in select mode', () => {
    // Regression guard for the interaction the class exists to protect: with
    // draggable left at "true", handleRowMouseDown must not toggle the row off.
    const row = element.querySelector('.creative-row')
    const tree = document.createElement('div')
    tree.className = 'creative-tree'
    tree.setAttribute('draggable', 'true')
    row.parentNode.insertBefore(tree, row)
    tree.appendChild(row)

    toggleButton.click()
    const checkbox = row.querySelector('.select-creative-checkbox')
    checkbox.checked = true
    row.classList.add('selected')

    row.dispatchEvent(new window.MouseEvent('mousedown', { bubbles: true, button: 0 }))

    expect(checkbox.checked).toBe(true)
    expect(row.classList.contains('selected')).toBe(true)
  })
})
