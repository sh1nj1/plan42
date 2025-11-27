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
    setDatasetValue(row, 'progressValue', inlinePayload.progress ?? '')
  }
  if (Object.prototype.hasOwnProperty.call(inlinePayload, 'origin_id')) {
    setDatasetValue(row, 'originId', inlinePayload.origin_id ?? '')
  }

  if (dirty && typeof row.requestUpdate === 'function') {
    row.requestUpdate()
  }
}

function createRow(node) {
  const row = document.createElement('creative-tree-row')
  applyRowProperties(row, node)
  return row
}

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

export function dispatchCreativeTreeUpdated(container) {
  if (!container) return
  const event = new CustomEvent('creative-tree:updated', { bubbles: true })
  container.dispatchEvent(event)
}
