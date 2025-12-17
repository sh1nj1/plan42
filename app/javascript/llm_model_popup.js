import CommonPopup from './lib/common_popup'

let llmModelPopupInitialized = false

if (!llmModelPopupInitialized) {
  llmModelPopupInitialized = true

  document.addEventListener('turbo:load', function () {
    const input = document.getElementById('user_llm_model')
    const menu = document.getElementById('llm-model-suggestions')

    if (!input || !menu) return

    const list = menu.querySelector('.mention-results') || menu.querySelector('.common-popup-list')
    const models = (input.dataset.llmModels || '')
      .split(',')
      .map((model) => model.trim())
      .filter(Boolean)

    if (!list || models.length === 0) return

    const popupMenu = new CommonPopup(menu, {
      listElement: list,
      renderItem: (model) => `<div class="mention-item">${model}</div>`,
      onSelect: (model) => {
        input.value = model
        popupMenu.hide()
        input.focus()
        input.dispatchEvent(new Event('input', { bubbles: true }))
        input.dispatchEvent(new Event('change', { bubbles: true }))
      },
    })

    function hide() {
      popupMenu.hide()
    }

    function show(term) {
      const lowered = term.toLowerCase()
      const filtered = models.filter((model) => model.toLowerCase().includes(lowered))

      if (filtered.length === 0) {
        hide()
        return
      }

      popupMenu.setItems(filtered)
      popupMenu.showAt(input.getBoundingClientRect())
    }

    input.addEventListener('keydown', function (event) {
      if (popupMenu.handleKey(event)) return
    })

    input.addEventListener('input', function () {
      show(input.value.trim())
    })

    input.addEventListener('focus', function () {
      show(input.value.trim())
    })

    input.addEventListener('blur', function () {
      setTimeout(hide, 150)
    })
  })
}
