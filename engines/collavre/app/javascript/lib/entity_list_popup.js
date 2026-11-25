export function entityListPopup(owner, id) {
    const modal = document.getElementById(id)
    return modal && owner.application.getControllerForElementAndIdentifier(modal, 'entity-list')
}

export function closeEntityListPopup(owner, id) {
    const modal = owner.element.querySelector(`#${id}`)
    const popup = modal && owner.application.getControllerForElementAndIdentifier(modal, 'entity-list')
    popup?.close()
    modal?.remove()
}

export function toggleEntityListPopup({ owner, id, placeholder, open, setExpanded }) {
    let modal = document.getElementById(id)
    if (modal) {
        const popup = entityListPopup(owner, id)
        if (popup?.popup?.isOpen()) {
            popup.close()
            setExpanded(false)
        } else if (popup) {
            open(popup)
        }
        return
    }

    modal = document.createElement('div')
    modal.id = id
    modal.className = 'common-popup'
    modal.style.display = 'none'
    modal.dataset.controller = 'entity-list'
    modal.dataset.closeLabel = owner.element.dataset.closeLabel || ''
    modal.innerHTML = `
      <button type="button" class="popup-close-btn" data-entity-list-target="close">&times;</button>
      <input type="text" class="shared-input-surface" style="width:100%;margin-bottom:0.5em;"
        data-entity-list-target="input">
      <ul class="common-popup-list" data-popup-list data-entity-list-target="list"></ul>
    `
    modal.querySelector('input').placeholder = placeholder
    owner.element.appendChild(modal)
    requestAnimationFrame(() => {
        const popup = owner.application.getControllerForElementAndIdentifier(modal, 'entity-list')
        if (popup) open(popup)
        else console.error('entity-list controller not found after creation')
    })
}
