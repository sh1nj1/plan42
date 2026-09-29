/**
 * @jest-environment jsdom
 */
import { Application } from '@hotwired/stimulus'

const { default: ToolCategoryController } = await import('../tool_category_controller')

describe('ToolCategoryController', () => {
  let application

  async function mount(checked = [false, false, false], { withCount = true } = {}) {
    const tools = checked.map((isChecked, index) => `
      <input type="checkbox" name="tools[]" value="tool_${index}"${isChecked ? ' checked' : ''}
             data-tool-category-target="tool" data-action="change->tool-category#sync">
    `).join('')
    document.body.innerHTML = `
      <fieldset data-controller="tool-category">
        <legend>
          <input type="checkbox" id="toggle" data-tool-category-target="toggle"
                 data-action="change->tool-category#toggle">
          ${withCount ? '<span data-tool-category-target="count"></span>' : ''}
        </legend>
        ${tools}
      </fieldset>
    `
    application = Application.start()
    application.register('tool-category', ToolCategoryController)
    await new Promise((resolve) => setTimeout(resolve, 0))
  }

  const toggle = () => document.getElementById('toggle')
  const tools = () => Array.from(document.querySelectorAll('input[name="tools[]"]'))
  const count = () => document.querySelector('[data-tool-category-target="count"]').textContent

  afterEach(() => {
    application?.stop()
    document.body.innerHTML = ''
  })

  it('starts unchecked when no tool is selected', async () => {
    await mount([false, false])
    expect(toggle().checked).toBe(false)
    expect(toggle().indeterminate).toBe(false)
    expect(count()).toBe('0')
  })

  it('shows indeterminate state for partial selection', async () => {
    await mount([true, false, false])
    expect(toggle().checked).toBe(false)
    expect(toggle().indeterminate).toBe(true)
    expect(count()).toBe('1')
  })

  it('starts checked when every tool is selected', async () => {
    await mount([true, true])
    expect(toggle().checked).toBe(true)
    expect(toggle().indeterminate).toBe(false)
  })

  it('checks and unchecks every tool from the category checkbox', async () => {
    await mount([true, false, false])

    toggle().click()
    expect(tools().every((tool) => tool.checked)).toBe(true)
    expect(toggle().indeterminate).toBe(false)
    expect(count()).toBe('3')

    toggle().click()
    expect(tools().some((tool) => tool.checked)).toBe(false)
    expect(count()).toBe('0')
  })

  it('updates the category checkbox when individual tools change', async () => {
    await mount([false, false])

    tools()[0].click()
    expect(toggle().indeterminate).toBe(true)

    tools()[1].click()
    expect(toggle().checked).toBe(true)
    expect(toggle().indeterminate).toBe(false)
    expect(count()).toBe('2')
  })

  it('works without a count target', async () => {
    await mount([true], { withCount: false })
    expect(toggle().checked).toBe(true)
  })
})
