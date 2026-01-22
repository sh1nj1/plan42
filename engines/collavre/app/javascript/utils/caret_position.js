export function getCaretClientRect(input) {
  if (!input || typeof input.selectionStart !== 'number') return null

  const selectionIndex = input.selectionStart
  const computed = window.getComputedStyle(input)
  const div = document.createElement('div')
  const properties = [
    'fontFamily', 'fontSize', 'fontWeight', 'fontStyle', 'letterSpacing',
    'textTransform', 'textRendering', 'textAlign', 'paddingTop', 'paddingRight',
    'paddingBottom', 'paddingLeft', 'borderTopWidth', 'borderRightWidth',
    'borderBottomWidth', 'borderLeftWidth', 'lineHeight', 'whiteSpace', 'wordBreak'
  ]

  properties.forEach((prop) => {
    div.style[prop] = computed[prop]
  })

  const rect = input.getBoundingClientRect()
  div.style.position = 'absolute'
  div.style.left = `${rect.left + window.scrollX}px`
  div.style.top = `${rect.top + window.scrollY}px`
  div.style.whiteSpace = 'pre-wrap'
  div.style.wordWrap = 'break-word'
  div.style.visibility = 'hidden'
  div.style.boxSizing = 'border-box'
  div.style.width = `${input.clientWidth}px`
  div.style.minHeight = `${input.clientHeight}px`

  const before = document.createTextNode(input.value.slice(0, selectionIndex))
  const marker = document.createElement('span')
  marker.textContent = '\u200b'

  div.appendChild(before)
  div.appendChild(marker)

  document.body.appendChild(div)
  div.scrollTop = input.scrollTop
  const caretRect = marker.getBoundingClientRect()
  document.body.removeChild(div)

  return caretRect
}
