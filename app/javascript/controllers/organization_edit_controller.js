import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
    static targets = ['modal', 'searchInput', 'results', 'organizationName', 'userInfo', 'updateBtn']
    static values = {
        searchUrl: String,
        updateUrl: String,
        noResultsText: String,
        searchFailedText: String,
        confirmMessage: String
    }

    connect() {
        this.searchTimeout = null
        this.currentUserId = null
        this.currentUserName = null
        this.currentOrganization = null
        this.selectedOrganizationIdx = null
        this.selectedOrganizationName = null
    }

    disconnect() {
        clearTimeout(this.searchTimeout)
    }

    openModal(event) {
        this.currentUserId = event.currentTarget.dataset.userId
        this.currentUserName = event.currentTarget.dataset.userName
        this.currentOrganization = event.currentTarget.dataset.currentOrganization || ''

        this.userInfoTarget.textContent = this.currentUserName

        // Reset selection state
        this.selectedOrganizationIdx = null
        this.selectedOrganizationName = null
        this.updateBtnTarget.disabled = true

        this.modalTarget.style.display = 'flex'
        this.searchInputTarget.value = ''
        this.resultsTarget.innerHTML = ''

        // Focus search input after a short delay to ensure modal is visible
        setTimeout(() => {
            this.searchInputTarget.focus()
        }, 100)

        // Close modal on Escape key
        this.escapeHandler = (e) => {
            if (e.key === 'Escape') {
                this.closeModal()
            }
        }
        document.addEventListener('keydown', this.escapeHandler)
    }

    closeModal() {
        this.modalTarget.style.display = 'none'
        this.currentUserId = null
        this.currentUserName = null
        this.currentOrganization = null
        this.selectedOrganizationIdx = null
        this.selectedOrganizationName = null
        document.removeEventListener('keydown', this.escapeHandler)
    }

    search() {
        clearTimeout(this.searchTimeout)

        const query = this.searchInputTarget.value.trim()
        if (query.length < 1) {
            this.resultsTarget.innerHTML = ''
            return
        }

        // Debounce: wait 300ms before searching
        this.searchTimeout = setTimeout(() => {
            this.performSearch(query)
        }, 300)
    }

    async performSearch(query) {
        try {
            const url = `${this.searchUrlValue}?query=${encodeURIComponent(query)}`
            const response = await fetch(url, {
                headers: {
                    'Accept': 'application/json'
                }
            })

            if (!response.ok) {
                throw new Error('Search failed')
            }

            const organizations = await response.json()
            this.renderResults(organizations)
        } catch (error) {
            console.error('Organization search error:', error)
            this.resultsTarget.innerHTML = `<p class="text-muted">${this.escapeHtml(this.searchFailedTextValue)}</p>`
        }
    }

    renderResults(organizations) {
        if (organizations.length === 0) {
            this.resultsTarget.innerHTML = `<p class="text-muted">${this.escapeHtml(this.noResultsTextValue)}</p>`
            return
        }

        const html = organizations.map(org => {
            const isSelected = this.selectedOrganizationIdx === String(org.organization_idx)
            const selectedClass = isSelected ? ' selected' : ''
            return `
            <div class="organization-result-item${selectedClass}"
                 data-action="click->organization-edit#selectOrganization"
                 data-organization-idx="${org.organization_idx}"
                 data-organization-name="${this.escapeHtml(org.organization_name)}">
                ${this.escapeHtml(org.organization_name)}
            </div>
        `}).join('')

        this.resultsTarget.innerHTML = html
    }

    selectOrganization(event) {
        const organizationIdx = event.currentTarget.dataset.organizationIdx
        const organizationName = event.currentTarget.dataset.organizationName

        // Store the selected organization
        this.selectedOrganizationIdx = organizationIdx
        this.selectedOrganizationName = organizationName

        // Update visual selection
        this.resultsTarget.querySelectorAll('.organization-result-item').forEach(item => {
            item.classList.remove('selected')
        })
        event.currentTarget.classList.add('selected')

        // Enable the update button
        this.updateBtnTarget.disabled = false
    }

    async confirmUpdate() {
        if (!this.currentUserId || !this.selectedOrganizationIdx) {
            return
        }

        // Build confirmation message
        const message = this.confirmMessageValue
            .replace(':user_name', this.currentUserName)
            .replace(':old_organization', this.currentOrganization || 'N/A')
            .replace(':new_organization', this.selectedOrganizationName)

        if (!confirm(message)) {
            return
        }

        try {
            const url = this.updateUrlValue.replace(':id', this.currentUserId)
            const response = await fetch(url, {
                method: 'PATCH',
                headers: {
                    'Content-Type': 'application/json',
                    'Accept': 'application/json',
                    'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content
                },
                body: JSON.stringify({
                    organization_idx: this.selectedOrganizationIdx
                })
            })

            const result = await response.json()

            if (result.success) {
                // Update the organization name in the table
                this.updateOrganizationInTable(this.currentUserId, result.organization_name)
                // Also update the data attribute on the edit button
                this.updateEditButtonData(this.currentUserId, result.organization_name)
                this.closeModal()
            } else {
                alert(result.message || 'Failed to update organization')
            }
        } catch (error) {
            console.error('Update organization error:', error)
            alert('Failed to update organization. Please try again.')
        }
    }

    updateOrganizationInTable(userId, organizationName) {
        // Find the organization name span for this user
        const orgNameSpan = this.organizationNameTargets.find(
            el => el.dataset.userId === userId
        )
        if (orgNameSpan) {
            orgNameSpan.textContent = organizationName
        }
    }

    updateEditButtonData(userId, organizationName) {
        // Find the edit button for this user and update its data-current-organization
        const editBtn = this.element.querySelector(`button[data-user-id="${userId}"][data-action*="openModal"]`)
        if (editBtn) {
            editBtn.dataset.currentOrganization = organizationName
        }
    }

    escapeHtml(text) {
        const div = document.createElement('div')
        div.textContent = text
        return div.innerHTML
    }
}
