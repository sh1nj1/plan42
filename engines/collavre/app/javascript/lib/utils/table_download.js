/**
 * Table Download Utility
 *
 * Detects rendered <table> elements within comment content and adds
 * download buttons (CSV / Excel) above each table.
 */

function getI18n(commentEl) {
  const popup = commentEl.closest('#comments-popup')
  return {
    csv: popup?.dataset?.tableDownloadCsvText || 'CSV',
    excel: popup?.dataset?.tableDownloadExcelText || 'Excel',
  }
}

function parseTable(table) {
  const rows = []
  table.querySelectorAll('tr').forEach((tr) => {
    const cells = []
    tr.querySelectorAll('th, td').forEach((cell) => {
      cells.push(cell.textContent.trim())
    })
    rows.push(cells)
  })
  return rows
}

function escapeCsvCell(value) {
  if (/[",\n\r]/.test(value)) {
    return `"${value.replace(/"/g, '""')}"`
  }
  return value
}

function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

function downloadCsv(rows, filename) {
  const csv = rows.map((row) => row.map(escapeCsvCell).join(',')).join('\r\n')
  // BOM for Excel UTF-8 compatibility
  const blob = new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8' })
  downloadBlob(blob, filename)
}

function downloadExcel(rows, filename) {
  const escapeXml = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

  const headerRow = rows[0] || []
  const dataRows = rows.slice(1)

  let xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
  xml += '<?mso-application progid="Excel.Sheet"?>\n'
  xml += '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"\n'
  xml += '  xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">\n'
  xml += '  <Styles>\n'
  xml += '    <Style ss:ID="header"><Font ss:Bold="1"/></Style>\n'
  xml += '  </Styles>\n'
  xml += '  <Worksheet ss:Name="Sheet1">\n'
  xml += '    <Table>\n'

  // Header row
  if (headerRow.length) {
    xml += '      <Row>\n'
    headerRow.forEach((cell) => {
      xml += `        <Cell ss:StyleID="header"><Data ss:Type="String">${escapeXml(cell)}</Data></Cell>\n`
    })
    xml += '      </Row>\n'
  }

  // Data rows
  dataRows.forEach((row) => {
    xml += '      <Row>\n'
    row.forEach((cell) => {
      const type = isNaN(cell) || cell === '' ? 'String' : 'Number'
      xml += `        <Cell><Data ss:Type="${type}">${escapeXml(cell)}</Data></Cell>\n`
    })
    xml += '      </Row>\n'
  })

  xml += '    </Table>\n'
  xml += '  </Worksheet>\n'
  xml += '</Workbook>'

  const blob = new Blob([xml], { type: 'application/vnd.ms-excel;charset=utf-8' })
  downloadBlob(blob, filename)
}

function generateFilename(table, index) {
  // Try to use the first header cell as a hint for the filename
  const firstHeader = table.querySelector('th')
  if (firstHeader) {
    const hint = firstHeader.textContent.trim().slice(0, 30).replace(/[^a-zA-Z0-9가-힣_-]/g, '_')
    if (hint) return `table_${hint}`
  }
  return `table_${index + 1}`
}

function createToolbar(table, index, i18n) {
  const toolbar = document.createElement('div')
  toolbar.className = 'table-download-toolbar'

  const csvBtn = document.createElement('button')
  csvBtn.type = 'button'
  csvBtn.className = 'table-download-btn'
  csvBtn.textContent = `\u2913 ${i18n.csv}`
  csvBtn.addEventListener('click', (e) => {
    e.preventDefault()
    e.stopPropagation()
    const rows = parseTable(table)
    const filename = generateFilename(table, index)
    downloadCsv(rows, `${filename}.csv`)
  })

  const excelBtn = document.createElement('button')
  excelBtn.type = 'button'
  excelBtn.className = 'table-download-btn'
  excelBtn.textContent = `\u2913 ${i18n.excel}`
  excelBtn.addEventListener('click', (e) => {
    e.preventDefault()
    e.stopPropagation()
    const rows = parseTable(table)
    const filename = generateFilename(table, index)
    downloadExcel(rows, `${filename}.xls`)
  })

  toolbar.appendChild(csvBtn)
  toolbar.appendChild(excelBtn)
  return toolbar
}

/**
 * Scans the given content element for <table> tags and adds download
 * toolbars. Call this after markdown has been rendered into HTML.
 */
export function addTableDownloadButtons(contentElement) {
  if (!contentElement) return

  const tables = contentElement.querySelectorAll('table')
  if (!tables.length) return

  const i18n = getI18n(contentElement)

  tables.forEach((table, index) => {
    // Skip if already wrapped
    if (table.parentElement?.classList.contains('table-download-wrapper')) return

    const wrapper = document.createElement('div')
    wrapper.className = 'table-download-wrapper'

    const toolbar = createToolbar(table, index, i18n)
    table.parentNode.insertBefore(wrapper, table)
    wrapper.appendChild(toolbar)
    wrapper.appendChild(table)
  })
}
