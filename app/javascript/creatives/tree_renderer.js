function normalizeBoolean(value) {
  return value === true || value === 'true' || value === ''
}

function setDatasetValue(element, key, value) {
  if (!element) return
  if (value === undefined || value === null || value === '') {
    delete element.dataset[key]
  } else {
    element.dataset[key] = value
  }
}

function buildRow(node) {
  const row = document.createElement('creative-tree-row')
  if (node.id != null) {
    row.creativeId = node.id
    row.setAttribute('creative-id', node.id)
  }
  if (node.dom_id) {
    row.domId = node.dom_id
    row.setAttribute('dom-id', node.dom_id)
  }
  if (node.parent_id != null) {
    row.parentId = node.parent_id
    row.setAttribute('parent-id', node.parent_id)
  } else {
    row.parentId = null
    row.removeAttribute('parent-id')
  }
  if (node.level != null) {
    row.level = Number(node.level)
    row.setAttribute('level', node.level)
  }
  if (node.select_mode != null) {
    row.selectMode = normalizeBoolean(node.select_mode)
    if (row.selectMode) {
      row.setAttribute('select-mode', '')
    } else {
      row.removeAttribute('select-mode')
    }
  }
  if (node.can_write != null) {
    row.canWrite = normalizeBoolean(node.can_write)
    if (row.canWrite) {
      row.setAttribute('can-write', '')
    } else {
      row.removeAttribute('can-write')
    }
  }
  if (node.has_children != null) {
    const value = normalizeBoolean(node.has_children)
    row.hasChildren = value
    if (value) {
      row.setAttribute('has-children', '')
    } else {
      row.removeAttribute('has-children')
    }
  }
  if (node.expanded != null) {
    const value = normalizeBoolean(node.expanded)
    row.expanded = value
    if (value) {
      row.setAttribute('expanded', '')
    } else {
      row.removeAttribute('expanded')
    }
  }
  if (node.is_root != null) {
    const value = normalizeBoolean(node.is_root)
    row.isRoot = value
    if (value) {
      row.setAttribute('is-root', '')
    } else {
      row.removeAttribute('is-root')
    }
  }
  if (node.link_url) {
    row.linkUrl = node.link_url
    row.setAttribute('link-url', node.link_url)
  }

  const templates = node.templates || {}
  if (templates.description_html != null) {
    row.descriptionHtml = templates.description_html
    setDatasetValue(row, 'descriptionHtml', templates.description_html)
  }
  if (templates.progress_html != null) {
    row.progressHtml = templates.progress_html
    setDatasetValue(row, 'progressHtml', templates.progress_html)
  }
  if (templates.edit_icon_html != null) {
    row.editIconHtml = templates.edit_icon_html
    setDatasetValue(row, 'editIconHtml', templates.edit_icon_html)
  }
  if (templates.edit_off_icon_html != null) {
    row.editOffIconHtml = templates.edit_off_icon_html
    setDatasetValue(row, 'editOffIconHtml', templates.edit_off_icon_html)
  }
  if (templates.origin_link_html != null) {
    row.originLinkHtml = templates.origin_link_html
    setDatasetValue(row, 'originLinkHtml', templates.origin_link_html)
  }

  return row
}

function buildChildrenContainer(node) {
  const container = document.createElement('div')
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
  }
  container.style.display = expanded || loaded ? '' : 'none'
  return container
}

function appendNodes(container, nodes) {
  if (!container || !Array.isArray(nodes) || nodes.length === 0) return
  const fragment = document.createDocumentFragment()

  nodes.forEach((node) => {
    const row = buildRow(node)
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

export function renderCreativeTree(container, nodes, { replace = true } = {}) {
  if (!container) return
  if (replace) {
    container.innerHTML = ''
  }
  appendNodes(container, nodes)
}

export function dispatchCreativeTreeUpdated(container) {
  if (!container) return
  const event = new CustomEvent('creative-tree:updated', { bubbles: true })
  container.dispatchEvent(event)
}
