// Creative guide popover functionality
// Handles the help button click and popover display

// Single document-level click handler for dismissing popover (delegated)
let documentClickHandlerAttached = false

function setupDocumentClickHandler() {
  if (documentClickHandlerAttached) return
  documentClickHandlerAttached = true

  document.addEventListener('click', function(e) {
    const popover = document.getElementById('creative-guide-popover')
    if (!popover || popover.style.display !== 'block') return

    const links = document.querySelectorAll('.creative-guide-link')
    const isClickOnLink = Array.from(links).some(link => link.contains(e.target))
    const isClickOnPopover = popover.contains(e.target)

    if (!isClickOnLink && !isClickOnPopover) {
      popover.style.display = 'none'
    }
  })
}

function setupCreativeGuide() {
  const links = document.querySelectorAll('.creative-guide-link')
  const popover = document.getElementById('creative-guide-popover')
  const close = document.getElementById('close-creative-guide')

  if (links.length && popover && close) {
    links.forEach(function(link) {
      // Use onclick assignment to avoid duplicate listeners
      link.onclick = function(e) {
        if (link.dataset.helpUrl) {
          window.location.href = link.dataset.helpUrl
          return
        }
        e.preventDefault()
        popover.style.display = 'block'
      }
    })

    // Use onclick assignment for close button
    close.onclick = function() {
      popover.style.display = 'none'
    }

    // Set up single document click handler
    setupDocumentClickHandler()
  }
}

document.addEventListener('turbo:load', setupCreativeGuide)
