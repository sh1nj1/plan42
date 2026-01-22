// Share creative modal functionality
// Handles share button click, invite link generation, and modal interactions

document.addEventListener('turbo:load', function() {
  const shareBtn = document.getElementById('share-creative-btn')
  const modal = document.getElementById('share-creative-modal')
  const closeBtn = document.getElementById('close-share-modal')
  const emailInput = document.getElementById('share-user-email')
  const inviteLinkBtn = document.getElementById('creative-invite-link')
  const permissionSelect = document.getElementById('share-permission')

  if (inviteLinkBtn) {
    inviteLinkBtn.onclick = function() {
      const creativeId = inviteLinkBtn.dataset.creativeId
      const permission = permissionSelect ? permissionSelect.value : 'read'
      const permissionLabel = permissionSelect ? permissionSelect.options[permissionSelect.selectedIndex].text : ''
      const noAccessMessage = inviteLinkBtn.dataset.noAccessMessage || 'Cannot create invite link for "No Access" permission.'
      const copiedTemplate = inviteLinkBtn.dataset.copiedTemplate || 'Invite link copied with __PERMISSION__ permission!'

      if (permission === 'no_access') {
        alert(noAccessMessage)
        return
      }
      fetch('/invite', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: JSON.stringify({ creative_id: creativeId, permission: permission })
      }).then(r => r.json()).then(data => {
        const plan42Copy = window.Plan42 && window.Plan42.copyTextToClipboard
        let copyPromise = null
        if (plan42Copy) {
          copyPromise = plan42Copy(data.url)
        } else if (navigator.clipboard && navigator.clipboard.writeText) {
          copyPromise = navigator.clipboard.writeText(data.url)
        }
        if (copyPromise) {
          copyPromise.then(function() {
            alert(copiedTemplate.replace('__PERMISSION__', permissionLabel))
          })
        }
      })
    }
  }

  if (shareBtn && modal && closeBtn) {
    shareBtn.onclick = function() {
      modal.style.display = 'flex'
      document.body.classList.add('no-scroll')
    }
    closeBtn.onclick = function() {
      modal.style.display = 'none'
      document.body.classList.remove('no-scroll')
    }
    modal.onclick = function(e) {
      if (e.target === modal) {
        modal.style.display = 'none'
        document.body.classList.remove('no-scroll')
      }
    }
    const params = new URLSearchParams(window.location.search)
    const reqEmail = params.get('share_request')
    if (reqEmail) {
      shareBtn.click()
      if (emailInput) {
        emailInput.value = reqEmail
        emailInput.dispatchEvent(new Event('blur'))
      }
    }
  }
})
