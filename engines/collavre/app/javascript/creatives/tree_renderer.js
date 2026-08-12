function normalizeBoolean(value) {
  return value === true || value === 'true' || value === ''
}

function setDatasetValue(element, key, value) {
  if (!element) return
  if (value === undefined || value === null) {
    delete element.dataset[key]
  } else {
    element.dataset[key] = String(value)
  }
}

// Capture current DOM state of the progress area back into Lit's progressHtml
// so that Turbo Streams DOM mutations (e.g. badge count updates) survive Lit re-renders.
// Lit renders progressHtml via unsafeHTML() inside a .creative-progress-area wrapper.
// Turbo may directly replace child elements (e.g. comment-badge span) in the DOM,
// but Lit's progressHtml string remains stale. On next re-render, Lit would overwrite
// the Turbo-updated DOM with the stale string, losing badge updates.
function syncProgressHtmlFromDom(row) {
  if (!row.progressHtml) return
  const wrapper = row.querySelector('.creative-progress-area')
  if (!wrapper) return
  const currentHtml = wrapper.innerHTML
  if (currentHtml && currentHtml !== row.progressHtml) {
    row.progressHtml = currentHtml
    row.dataset.progressHtml = currentHtml
  }
}

export function updateProgressHtml(html, progress, displayText) {
  const complete = Number(progress) === 1
  const checkboxRegex = /<input\b[^>]*class="progress-toggle-checkbox"[^>]*>/

  if (checkboxRegex.test(html)) {
    let updated = html.replace(checkboxRegex, input => {
      const unchecked = input.replace(/\schecked(?:="checked")?/g, '')
      return complete ? unchecked.replace(/>$/, ' checked="checked">') : unchecked
    })

    updated = updated.replace(/<span\b[^>]*data-progress-toggle="true"[^>]*>/, wrap => {
      const labelName = complete ? 'markIncomplete' : 'markComplete'
      const label = wrap.match(new RegExp(`data-${labelName.replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}="([^"]*)"`))?.[1]
      let next = wrap
        .replace(/data-current-progress="[^"]*"/, `data-current-progress="${progress}"`)
        .replace(/data-new-progress="[^"]*"/, `data-new-progress="${complete ? 0 : 1}"`)
      return label ? next.replace(/title="[^"]*"/, `title="${label}"`) : next
    })
    return updated
  }

  const cssClass = complete ? 'creative-progress-complete' : 'creative-progress-incomplete'
  const replaced = html.replace(
    /(<span[^>]*class="creative-progress-(?:in)?complete"[^>]*>)[^<]*(<\/span>)/,
    `$1${displayText}$2`
  )
  return replaced === html ? html : replaced.replace(
    /class="creative-progress-(?:in)?complete"/,
    `class="${cssClass}"`
  )
}

function applyRowProperties(row, node) {
  if (!row || !node) return
  let dirty = false

  if (node.id != null && row.creativeId !== node.id) {
    row.creativeId = node.id
    row.setAttribute('creative-id', node.id)
    dirty = true
  }
  if (node.dom_id && row.domId !== node.dom_id) {
    row.domId = node.dom_id
    row.setAttribute('dom-id', node.dom_id)
    dirty = true
  }
  if (node.parent_id != null) {
    if (row.parentId !== node.parent_id) {
      row.parentId = node.parent_id
      dirty = true
    }
    row.setAttribute('parent-id', node.parent_id)
  } else if (row.hasAttribute?.('parent-id')) {
    row.parentId = null
    row.removeAttribute('parent-id')
    dirty = true
  }
  if (node.level != null) {
    const level = Number(node.level)
    if (row.level !== level) {
      row.level = level
      dirty = true
    }
    row.setAttribute('level', node.level)
  }
  if (node.sequence != null) {
    row.setAttribute('sequence', node.sequence)
  }

  const updateBooleanAttr = (prop, attr, value) => {
    if (value == null) return
    const normalized = normalizeBoolean(value)
    if (row[prop] !== normalized) {
      row[prop] = normalized
      dirty = true
    }
    if (normalized) {
      row.setAttribute(attr, '')
    } else {
      row.removeAttribute(attr)
    }
  }

  updateBooleanAttr('selectMode', 'select-mode', node.select_mode)
  updateBooleanAttr('canWrite', 'can-write', node.can_write)
  updateBooleanAttr('hasChildren', 'has-children', node.has_children)
  updateBooleanAttr('expanded', 'expanded', node.expanded)
  updateBooleanAttr('isRoot', 'is-root', node.is_root)
  updateBooleanAttr('archived', 'archived', node.archived)
  updateBooleanAttr('githubSource', 'github-source', node.github_source)

  if (node.link_url) {
    if (row.linkUrl !== node.link_url) {
      row.linkUrl = node.link_url
      dirty = true
    }
    row.setAttribute('link-url', node.link_url)
  }

  const templates = node.templates || {}
  if (templates.description_html != null && row.descriptionHtml !== templates.description_html) {
    row.descriptionHtml = templates.description_html
    setDatasetValue(row, 'descriptionHtml', templates.description_html)
    dirty = true
  }
  if (templates.progress_html != null && row.progressHtml !== templates.progress_html) {
    row.progressHtml = templates.progress_html
    setDatasetValue(row, 'progressHtml', templates.progress_html)
    dirty = true
  }
  if (templates.edit_icon_html != null && row.editIconHtml !== templates.edit_icon_html) {
    row.editIconHtml = templates.edit_icon_html
    setDatasetValue(row, 'editIconHtml', templates.edit_icon_html)
    dirty = true
  }
  if (templates.edit_off_icon_html != null && row.editOffIconHtml !== templates.edit_off_icon_html) {
    row.editOffIconHtml = templates.edit_off_icon_html
    setDatasetValue(row, 'editOffIconHtml', templates.edit_off_icon_html)
    dirty = true
  }
  if (templates.origin_link_html != null && row.originLinkHtml !== templates.origin_link_html) {
    row.originLinkHtml = templates.origin_link_html
    setDatasetValue(row, 'originLinkHtml', templates.origin_link_html)
    dirty = true
  }

  const inlinePayload = node.inline_editor_payload || {}
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'description_raw_html')) {
    setDatasetValue(row, 'descriptionRawHtml', inlinePayload.description_raw_html ?? '')
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'progress')) {
    const rawProgress = inlinePayload.progress ?? 0
    const pct = Math.round(rawProgress * 100)
    // progress_text from server: completion mark string, empty string (=complete but no mark), or undefined
    const displayText = node.progress_text != null ? (node.progress_text || '\u00a0\u00a0') : `${pct}%`
    setDatasetValue(row, 'progressValue', rawProgress)
    // Update progress percentage in existing progressHtml without replacing full HTML
    // (preserves chat badges, comment counts, etc.)
    if (templates.progress_html == null) {
      let updated = row.progressHtml || ''
      if (updated) {
        updated = updateProgressHtml(updated, rawProgress, displayText)
      }
      if (updated !== (row.progressHtml || '')) {
        row.progressHtml = updated
        setDatasetValue(row, 'progressHtml', updated)
        dirty = true
      }
    }
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'origin_id')) {
    setDatasetValue(row, 'originId', inlinePayload.origin_id ?? '')
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'content_type')) {
    setDatasetValue(row, 'contentType', inlinePayload.content_type ?? '')
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'markdown_source')) {
    setDatasetValue(row, 'markdownSource', inlinePayload.markdown_source ?? '')
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'markdown_editor')) {
    setDatasetValue(row, 'markdownEditor', inlinePayload.markdown_editor ?? '')
  }

  if (dirty && typeof row.requestUpdate === 'function') {
    // Before Lit re-renders, sync progressHtml from current DOM.
    // Turbo Streams may have replaced badge elements directly in the DOM
    // (e.g. comment badge count), but the Lit progressHtml string still
    // holds the stale initial HTML. On re-render, Lit would overwrite
    // the Turbo-updated DOM with the stale string, losing badges.
    syncProgressHtmlFromDom(row)
    row.requestUpdate()
  }
}

export function createRow(node) {
  const row = document.createElement('creative-tree-row')
  applyRowProperties(row, node)
  return row
}

export { applyRowProperties }

function applyChildrenContainerProperties(container, node) {
  if (!container || !node) return
  container.className = 'creative-children'
  if (node.id) {
    container.id = node.id
  }
  if (node.level != null) {
    setDatasetValue(container, 'level', String(node.level))
  }
  const expanded = normalizeBoolean(node.expanded)
  const loaded = normalizeBoolean(node.loaded)
  container.dataset.expanded = expanded ? 'true' : 'false'
  container.dataset.loaded = loaded ? 'true' : 'false'
  if (node.load_url) {
    container.dataset.loadUrl = node.load_url
  } else {
    delete container.dataset.loadUrl
  }
  container.style.display = expanded || loaded ? '' : 'none'
}

function buildChildrenContainer(node) {
  const container = document.createElement('div')
  applyChildrenContainerProperties(container, node)
  return container
}

function appendNodes(container, nodes) {
  if (!container || !Array.isArray(nodes) || nodes.length === 0) return
  const fragment = document.createDocumentFragment()

  nodes.forEach((node) => {
    const row = createRow(node)
    fragment.appendChild(row)

    const childData = node.children_container
    if (childData && childData.id) {
      const childrenContainer = buildChildrenContainer(childData)
      fragment.appendChild(childrenContainer)
      if (Array.isArray(childData.nodes) && childData.nodes.length > 0) {
        appendNodes(childrenContainer, childData.nodes)
      }
    }
  })

  container.appendChild(fragment)
}

function collectExistingElements(container) {
  const map = new Map()
  Array.from(container.children || []).forEach((child) => {
    if (child.matches?.('creative-tree-row')) {
      const domId = child.domId || child.getAttribute?.('dom-id') || child.querySelector?.('.creative-tree')?.id
      if (domId) {
        map.set(domId, child)
      }
    } else if (child.classList?.contains('creative-children')) {
      const id = child.id || child.dataset?.id
      if (id) {
        map.set(id, child)
      }
    }
  })
  return map
}

function reconcileNodes(container, nodes) {
  if (!container) return
  if (!Array.isArray(nodes) || nodes.length === 0) {
    container.innerHTML = ''
    return
  }

  const existing = collectExistingElements(container)
  const nextChildren = []

  nodes.forEach((node) => {
    let row = null
    if (node.dom_id && existing.has(node.dom_id)) {
      row = existing.get(node.dom_id)
      existing.delete(node.dom_id)
      applyRowProperties(row, node)
    } else {
      row = createRow(node)
    }
    nextChildren.push(row)

    const childData = node.children_container
    if (childData && childData.id) {
      let childrenContainer = null
      if (existing.has(childData.id)) {
        childrenContainer = existing.get(childData.id)
        existing.delete(childData.id)
        applyChildrenContainerProperties(childrenContainer, childData)
      } else {
        childrenContainer = buildChildrenContainer(childData)
      }
      nextChildren.push(childrenContainer)
      if (Array.isArray(childData.nodes) && childData.nodes.length > 0) {
        reconcileNodes(childrenContainer, childData.nodes)
      } else {
        childrenContainer.innerHTML = ''
      }
    }
  })

  container.replaceChildren(...nextChildren)
}

export function renderCreativeTree(container, nodes, { replace = true } = {}) {
  if (!container) return
  if (replace) {
    container.innerHTML = ''
    appendNodes(container, nodes)
    return
  }
  reconcileNodes(container, nodes)
}

// Append a page of flat nodes to an already-rendered list without clearing the
// existing rows. Used by the "Chats" feed's load-more, where each page is added
// below the previous one rather than replacing it.
export function appendCreativeNodes(container, nodes) {
  if (!container) return
  appendNodes(container, nodes)
}

export function dispatchCreativeTreeUpdated(container) {
  if (!container) return
  const event = new CustomEvent('creative-tree:updated', { bubbles: true })
  container.dispatchEvent(event)
}
