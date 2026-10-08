export function showShareMessage(text, type) {
    if (!text) return
    const modal = document.getElementById("share-creative-modal")
    if (!modal) return

    const existing = modal.querySelector(".share-modal-message")
    if (existing) existing.remove()

    const msg = document.createElement("div")
    msg.className = `share-modal-message share-modal-message-${type}`
    msg.textContent = text

    const title = modal.querySelector("h2")
    if (title) {
      title.insertAdjacentElement("afterend", msg)
    } else {
      modal.querySelector(".popup-box")?.prepend(msg)
    }

    setTimeout(() => msg.remove(), 4000)
}

export function initializePublicLink() {
    const copyBtn = document.getElementById("share-public-link-copy")
    const urlInput = document.getElementById("share-public-url")
    if (!copyBtn || !urlInput) return

    copyBtn.onclick = () => {
      const plan42Copy = window.Plan42 && window.Plan42.copyTextToClipboard
      const copyPromise = plan42Copy
        ? plan42Copy(urlInput.value)
        : navigator.clipboard?.writeText(urlInput.value)
      copyPromise?.then(() => showShareMessage(copyBtn.dataset.copiedMessage, "success"))
    }
}
