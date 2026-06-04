import CommonPopupController from './common_popup_controller'
import creativesApi from '../lib/api/creatives'

// Minimum characters before a text search fires. Below this the popup shows the
// browsable mini-tree instead (empty input => tree, >= MIN_QUERY chars => search).
const MIN_QUERY = 2

// Chevron icons matched to the main creative tree (creative_tree_row.js#_toggleIcon)
// so the mini-tree expand/collapse affordance is visually identical.
const CHEVRON_COLLAPSED =
    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6L15 12L9 18"/></svg>'
const CHEVRON_EXPANDED =
    '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9L12 15L18 9"/></svg>'

export default class extends CommonPopupController {
    static targets = ['input', 'list', 'close']

    connect() {
        super.connect()
        this._debounceTimer = null
        this._searchToken = 0
        this._mode = 'tree'
        this._rootNodes = null
        this._activeEl = null
        this.inputTarget.addEventListener('input', this._debouncedSearch.bind(this))
        this.inputTarget.addEventListener('keydown', this.handleInputKeydown.bind(this))
        this.closeTarget.addEventListener('click', () => this.close())

        // Bind public methods
        this.open = this.open.bind(this)
    }

    disconnect() {
        this._clearDebounce()
        super.disconnect()
    }

    open(anchorRect, onSelectCallback, onCloseCallback) {
        this.onSelectCallback = onSelectCallback
        this.onCloseCallback = onCloseCallback
        this._mode = 'tree'
        this._rootNodes = null
        this._activeEl = null
        this.inputTarget.value = ''
        // Clear any CommonPopup item state; we render our own DOM into the list.
        this.popup.setItems([])
        super.open(anchorRect)

        requestAnimationFrame(() => {
            this.inputTarget.focus()
        })

        this._showTree()
    }

    close() {
        this._clearDebounce()
        super.close()
    }

    _clearDebounce() {
        if (this._debounceTimer) {
            clearTimeout(this._debounceTimer)
            this._debounceTimer = null
        }
    }

    handleInputKeydown(event) {
        // CommonPopup's key handling is item-list based and we don't populate it,
        // so it is a no-op here. We drive navigation over our own rendered rows.
        if (event.key === 'Escape') {
            this.close()
            return
        }

        if (event.key === 'ArrowDown') {
            event.preventDefault()
            this._moveActive(1)
            return
        }

        if (event.key === 'ArrowUp') {
            event.preventDefault()
            this._moveActive(-1)
            return
        }

        if ((event.key === 'Enter' || event.key === 'Tab') && this._activeEl) {
            event.preventDefault()
            this._activateRow(this._activeEl)
            return
        }

        if (this._mode === 'tree' && this._activeEl) {
            if (event.key === 'ArrowRight') {
                event.preventDefault()
                this._expandNode(this._activeEl.closest('.link-tree-item'))
                return
            }
            if (event.key === 'ArrowLeft') {
                event.preventDefault()
                this._collapseNode(this._activeEl.closest('.link-tree-item'))
            }
        }
    }

    _debouncedSearch() {
        this._clearDebounce()
        this._debounceTimer = setTimeout(() => this.search(), 300)
    }

    search() {
        const query = this.inputTarget.value.trim()
        if (query.length < MIN_QUERY) {
            this._searchToken++
            this._showTree()
            return
        }

        this._mode = 'search'
        const token = ++this._searchToken
        creativesApi.search(query, { simple: true })
            .then((results) => {
                // Discard stale responses if input changed since this request
                if (token !== this._searchToken) return
                this._renderSearchResults(Array.isArray(results) ? results : [])
            })
            .catch(() => {
                if (token === this._searchToken) this._renderSearchResults([])
            })
    }

    // --- Tree (browse) mode --------------------------------------------------

    _showTree() {
        this._mode = 'tree'
        if (this._rootNodes) {
            this._renderTree(this._rootNodes)
            return
        }

        this._renderMessage(this._text('loadingText'))
        const token = ++this._searchToken
        creativesApi.browse(null)
            .then((nodes) => {
                if (token !== this._searchToken) return
                this._rootNodes = Array.isArray(nodes) ? nodes : []
                this._renderTree(this._rootNodes)
            })
            .catch(() => {
                if (token === this._searchToken) this._renderMessage(this._text('emptyText'))
            })
    }

    _renderTree(nodes) {
        this.listTarget.innerHTML = ''
        if (!nodes || nodes.length === 0) {
            this._renderMessage(this._text('emptyText'))
            return
        }
        nodes.forEach((node) => this.listTarget.appendChild(this._buildTreeItem(node, 0)))
        this._resetActive()
    }

    _buildTreeItem(node, level) {
        const li = document.createElement('li')
        li.className = 'link-tree-item'
        li.dataset.id = String(node.id)
        li.dataset.level = String(level)
        li.dataset.loaded = '0'
        // Linked-creative shells render under the user's shell id, but search
        // breadcrumbs carry the effective origin id. Record the origin id so
        // _findItem can resolve a breadcrumb's root crumb back to this shell.
        if (node.origin_id) li.dataset.originId = String(node.origin_id)

        const row = document.createElement('div')
        row.className = 'link-tree-row'
        row.setAttribute('data-pick-row', '')
        row.dataset.id = String(node.id)
        row.style.paddingLeft = `${level * 1.1 + 0.5}em`

        const toggle = document.createElement('button')
        toggle.type = 'button'
        toggle.className = 'link-tree-toggle'
        if (node.has_children) {
            toggle.innerHTML = CHEVRON_COLLAPSED
            toggle.setAttribute('aria-label', this._text('expandText'))
            toggle.addEventListener('mousedown', (e) => e.preventDefault())
            toggle.addEventListener('click', (e) => {
                e.preventDefault()
                e.stopPropagation()
                this._toggleNode(li)
            })
        } else {
            toggle.className = 'link-tree-toggle link-tree-toggle-empty'
            toggle.tabIndex = -1
            toggle.setAttribute('aria-hidden', 'true')
        }
        row.appendChild(toggle)

        const label = document.createElement('span')
        label.className = 'link-tree-label'
        label.textContent = node.description || ''
        row.appendChild(label)

        row.addEventListener('mouseenter', () => this._setActive(row))
        row.addEventListener('mousedown', (e) => e.preventDefault())
        row.addEventListener('click', () => this._activateRow(row))

        li.appendChild(row)

        if (node.has_children) {
            const childrenUl = document.createElement('ul')
            childrenUl.className = 'link-tree-children'
            childrenUl.hidden = true
            li.appendChild(childrenUl)
        }

        return li
    }

    _toggleNode(li) {
        if (!li) return
        if (li.classList.contains('expanded')) {
            this._collapseNode(li)
        } else {
            this._expandNode(li)
        }
    }

    _collapseNode(li) {
        if (!li || !li.classList.contains('expanded')) return
        li.classList.remove('expanded')
        const childrenUl = li.querySelector(':scope > .link-tree-children')
        if (childrenUl) childrenUl.hidden = true
        const toggle = li.querySelector(':scope > .link-tree-row > .link-tree-toggle')
        if (toggle && !toggle.classList.contains('link-tree-toggle-empty')) toggle.innerHTML = CHEVRON_COLLAPSED
    }

    // Returns a promise that resolves once the node is expanded (children loaded
    // and visible). Used both by user interaction and breadcrumb navigation.
    _expandNode(li) {
        if (!li) return Promise.resolve()
        const childrenUl = li.querySelector(':scope > .link-tree-children')
        if (!childrenUl) return Promise.resolve() // leaf

        const toggle = li.querySelector(':scope > .link-tree-row > .link-tree-toggle')
        li.classList.add('expanded')
        childrenUl.hidden = false
        if (toggle && !toggle.classList.contains('link-tree-toggle-empty')) toggle.innerHTML = CHEVRON_EXPANDED

        if (li.dataset.loaded === '1') return Promise.resolve()

        const level = parseInt(li.dataset.level, 10) + 1
        li.dataset.loaded = '1'
        childrenUl.innerHTML = `<li class="link-tree-loading">${this._escape(this._text('loadingText'))}</li>`

        return creativesApi.browse(li.dataset.id)
            .then((nodes) => {
                childrenUl.innerHTML = ''
                const list = Array.isArray(nodes) ? nodes : []
                if (list.length === 0) {
                    childrenUl.innerHTML = `<li class="link-tree-empty">${this._escape(this._text('emptyText'))}</li>`
                    return
                }
                list.forEach((child) => childrenUl.appendChild(this._buildTreeItem(child, level)))
            })
            .catch(() => {
                li.dataset.loaded = '0'
                childrenUl.innerHTML = ''
            })
    }

    // --- Search (flat + breadcrumb) mode -------------------------------------

    _renderSearchResults(results) {
        this.listTarget.innerHTML = ''
        if (!results || results.length === 0) {
            this._renderMessage(this._text('noResultsText'))
            return
        }

        results.forEach((result) => {
            const li = document.createElement('li')
            li.className = 'link-result-item'
            li.setAttribute('data-pick-row', '')
            li.dataset.id = String(result.id)

            const label = document.createElement('div')
            label.className = 'link-result-label'
            label.textContent = result.description || ''
            li.appendChild(label)

            if (Array.isArray(result.path) && result.path.length > 0) {
                li.appendChild(this._buildBreadcrumb(result))
            }

            li.addEventListener('mouseenter', () => this._setActive(li))
            li.addEventListener('mousedown', (e) => e.preventDefault())
            li.addEventListener('click', () => this._activateRow(li))

            this.listTarget.appendChild(li)
        })
        this._resetActive()
    }

    _buildBreadcrumb(result) {
        const nav = document.createElement('div')
        nav.className = 'link-result-path'

        result.path.forEach((crumb, index) => {
            if (index > 0) {
                const sep = document.createElement('span')
                sep.className = 'link-crumb-sep'
                sep.textContent = '›'
                nav.appendChild(sep)
            }
            // Ancestors the user cannot read are kept (to preserve depth) but
            // masked and non-navigable — clicking them would reveal nothing.
            if (crumb.restricted) {
                const masked = document.createElement('span')
                masked.className = 'link-crumb link-crumb-restricted'
                masked.textContent = '…'
                nav.appendChild(masked)
                return
            }

            const btn = document.createElement('button')
            btn.type = 'button'
            btn.className = 'link-crumb'
            btn.dataset.id = String(crumb.id)
            btn.textContent = crumb.description || ''
            btn.addEventListener('mousedown', (e) => e.preventDefault())
            btn.addEventListener('click', (e) => {
                e.preventDefault()
                e.stopPropagation()
                this._navigateToCrumb(result, index)
            })
            nav.appendChild(btn)
        })

        return nav
    }

    // Clicking a breadcrumb segment switches to the tree, expands the path down
    // to that ancestor, and highlights it — turning search into a jump-to-place.
    _navigateToCrumb(result, crumbIndex) {
        // When the hit lives under a linked shell nested in the user's own tree,
        // the origin-space crumbs omit the local folders above the shell. The
        // server-supplied reveal_path maps each origin ancestor id to the local
        // path ([localFolder..., shellId]) that surfaces *that* ancestor's shell.
        // Anchor at the entry at/above the clicked crumb (nearest first) so a
        // higher ancestor crumb resolves through its own shell, not a deeper one;
        // origins between the anchoring shell and the target render as the shell's
        // descendants, while origins above the anchor are not in the user's tree.
        const path = result.path
        const revealMap =
            result.reveal_path && typeof result.reveal_path === 'object' && !Array.isArray(result.reveal_path)
                ? result.reveal_path
                : null
        let localPrefix = []
        let anchorIndex = -1
        if (revealMap) {
            for (let i = crumbIndex; i >= 0; i--) {
                const entry = revealMap[String(path[i].id)]
                if (entry) {
                    localPrefix = entry.map(String)
                    anchorIndex = i
                    break
                }
            }
        }
        const originChain = path.slice(anchorIndex + 1, crumbIndex).map((p) => String(p.id))
        const chain = localPrefix.concat(originChain)
        const targetId = String(path[crumbIndex].id)

        this.inputTarget.value = ''
        this._searchToken++
        this._mode = 'tree'

        const reveal = () => this._expandChain(chain).then(() => this._highlight(targetId))

        if (this._rootNodes) {
            this._renderTree(this._rootNodes)
            reveal()
        } else {
            creativesApi.browse(null)
                .then((nodes) => {
                    this._rootNodes = Array.isArray(nodes) ? nodes : []
                    this._renderTree(this._rootNodes)
                    return reveal()
                })
                .catch(() => this._renderMessage(this._text('emptyText')))
        }
    }

    _expandChain(ids) {
        return ids.reduce((promise, id) => {
            return promise.then(() => {
                const li = this._findItem(id)
                return li ? this._expandNode(li) : null
            })
        }, Promise.resolve())
    }

    _highlight(id) {
        const li = this._findItem(id)
        if (!li) return
        const row = li.querySelector(':scope > .link-tree-row')
        if (row) {
            this._setActive(row)
            row.scrollIntoView({ block: 'nearest' })
        }
    }

    _findItem(id) {
        // Match the rendered node id first; fall back to the effective origin id
        // so a breadcrumb's root crumb (origin id) resolves to its linked shell.
        return (
            this.listTarget.querySelector(`.link-tree-item[data-id="${id}"]`) ||
            this.listTarget.querySelector(`.link-tree-item[data-origin-id="${id}"]`)
        )
    }

    // --- Selection & keyboard navigation -------------------------------------

    _activateRow(row) {
        if (!row || !row.hasAttribute('data-pick-row')) return
        // For a linked-creative shell row, emit the effective origin id, not the
        // shell id: consumers use the selected id as the new link's origin, and
        // linking to the shell (rather than the real shared creative) would make
        // PermissionChecker treat the shell as the permission base. Flat search
        // rows already carry the origin creative's id, so they pass through.
        const item = row.closest('.link-tree-item')
        const id = Number((item && item.dataset.originId) || row.dataset.id)
        const labelEl = row.querySelector('.link-tree-label, .link-result-label')
        const label = labelEl ? labelEl.textContent : ''
        this.select({ id, label })
    }

    // Override select to invoke callback
    select(item) {
        if (this.onSelectCallback) {
            this.onSelectCallback(item)
        }
        this.close()
    }

    _visibleRows() {
        return Array.from(this.listTarget.querySelectorAll('[data-pick-row]'))
            .filter((el) => el.offsetParent !== null)
    }

    _resetActive() {
        const rows = this._visibleRows()
        this._setActive(rows[0] || null)
    }

    _setActive(row) {
        if (this._activeEl === row) return
        if (this._activeEl) this._activeEl.classList.remove('active')
        this._activeEl = row
        if (row) row.classList.add('active')
    }

    _moveActive(delta) {
        const rows = this._visibleRows()
        if (rows.length === 0) return
        const current = rows.indexOf(this._activeEl)
        let next = current + delta
        if (next < 0) next = rows.length - 1
        if (next >= rows.length) next = 0
        const row = rows[next]
        this._setActive(row)
        row.scrollIntoView({ block: 'nearest' })
    }

    // --- Helpers -------------------------------------------------------------

    _renderMessage(text) {
        this.listTarget.innerHTML = ''
        const li = document.createElement('li')
        li.className = 'link-popup-message'
        li.textContent = text
        this.listTarget.appendChild(li)
        this._activeEl = null
    }

    _text(key) {
        const map = {
            loadingText: this.element.dataset.linkCreativeLoadingText,
            noResultsText: this.element.dataset.linkCreativeNoResultsText,
            emptyText: this.element.dataset.linkCreativeEmptyText,
            expandText: this.element.dataset.linkCreativeExpandText,
        }
        return map[key] || ''
    }

    _escape(text) {
        return String(text || '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;')
    }

    dispatchClose(reason) {
        if (this.onCloseCallback) {
            this.onCloseCallback()
            this.onCloseCallback = null
        }
        // Also clear the callback reference to avoid double calling if close() is called manually later
        this.onSelectCallback = null

        super.dispatchClose(reason)
    }
}
