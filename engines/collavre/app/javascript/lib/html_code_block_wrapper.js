/**
 * Wraps HTML tag blocks in a string with markdown code blocks.
 * Handles nested tags of the same name correctly.
 *
 * @param {string} text - The input text potentially containing HTML
 * @returns {{ changed: boolean, result: string }}
 */
export function wrapHtmlInCodeBlocks(text) {
  if (!text) return { changed: false, result: text }

  // If entire text is a single code block, skip
  if (text.trimStart().startsWith('```') && text.trimEnd().endsWith('```')) {
    return { changed: false, result: text }
  }

  const segments = extractHtmlSegments(text)
  if (!segments) return { changed: false, result: text }

  let result = ''
  let lastIndex = 0

  for (const seg of segments) {
    result += text.slice(lastIndex, seg.start)
    result += '\n\n```html\n' + seg.html + '\n```\n\n'
    lastIndex = seg.end
  }
  result += text.slice(lastIndex)

  // Trim leading/trailing newlines added by wrapping
  result = result.replace(/^\n+/, '').replace(/\n+$/, '')

  return { changed: true, result }
}

// Self-closing tag pattern: <tagname ... />
const SELF_CLOSING_RE = /<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*\/>/g

// Opening tag pattern: <tagname ...>
const OPEN_TAG_RE = /<([a-zA-Z][a-zA-Z0-9]*)\b[^>]*>/g

/**
 * Find HTML segments (paired open/close tags or self-closing tags) in text.
 * Returns array of { start, end, html } or null if no HTML found.
 */
function extractHtmlSegments(text) {
  const segments = []

  // First pass: find self-closing tags
  const selfClosing = []
  let m
  SELF_CLOSING_RE.lastIndex = 0
  while ((m = SELF_CLOSING_RE.exec(text)) !== null) {
    selfClosing.push({ start: m.index, end: m.index + m[0].length })
  }

  // Second pass: find paired open/close tags with nesting support
  let i = 0
  while (i < text.length) {
    // Skip positions inside already-found self-closing tags
    if (selfClosing.some((sc) => i >= sc.start && i < sc.end)) {
      const sc = selfClosing.find((sc) => i >= sc.start && i < sc.end)
      i = sc.end
      continue
    }

    // Look for opening tag at position i
    OPEN_TAG_RE.lastIndex = i
    const openMatch = OPEN_TAG_RE.exec(text)
    if (!openMatch || openMatch.index !== i) {
      i++
      continue
    }

    // Check if this is actually a self-closing tag
    if (openMatch[0].endsWith('/>')) {
      segments.push({
        start: openMatch.index,
        end: openMatch.index + openMatch[0].length,
        html: openMatch[0],
      })
      i = openMatch.index + openMatch[0].length
      continue
    }

    const tagName = openMatch[1]
    const searchStart = openMatch.index + openMatch[0].length

    // Find matching close tag with nesting support
    const closeIndex = findMatchingCloseTag(text, tagName, searchStart)
    if (closeIndex === -1) {
      i++
      continue
    }

    const closeTag = `</${tagName}>`
    const endPos = closeIndex + closeTag.length
    segments.push({
      start: openMatch.index,
      end: endPos,
      html: text.slice(openMatch.index, endPos),
    })
    i = endPos
    continue
  }

  // Add self-closing tags that aren't inside paired segments
  for (const sc of selfClosing) {
    if (!segments.some((seg) => sc.start >= seg.start && sc.end <= seg.end)) {
      segments.push({ start: sc.start, end: sc.end, html: text.slice(sc.start, sc.end) })
    }
  }

  if (segments.length === 0) return null

  // Sort by position
  segments.sort((a, b) => a.start - b.start)

  // Filter out segments inside existing markdown code blocks
  const codeBlockRanges = []
  const codeBlockRe = /^```[^\n]*\n[\s\S]*?^```/gm
  let cbMatch
  while ((cbMatch = codeBlockRe.exec(text)) !== null) {
    codeBlockRanges.push({ start: cbMatch.index, end: cbMatch.index + cbMatch[0].length })
  }
  if (codeBlockRanges.length > 0) {
    const filtered = segments.filter(
      (seg) => !codeBlockRanges.some((cb) => seg.start >= cb.start && seg.end <= cb.end)
    )
    return filtered.length > 0 ? filtered : null
  }

  return segments
}

/**
 * Find the matching close tag for tagName, handling nested same-name tags.
 * Returns the index of the matching </tagName> or -1.
 */
function findMatchingCloseTag(text, tagName, startFrom) {
  const openPattern = new RegExp(`<${tagName}\\b[^>]*>`, 'gi')
  const closePattern = new RegExp(`</${tagName}>`, 'gi')

  let depth = 1
  let pos = startFrom

  while (depth > 0 && pos < text.length) {
    openPattern.lastIndex = pos
    closePattern.lastIndex = pos

    const nextOpen = openPattern.exec(text)
    const nextClose = closePattern.exec(text)

    if (!nextClose) return -1 // No closing tag found

    if (nextOpen && nextOpen.index < nextClose.index && !nextOpen[0].endsWith('/>')) {
      // Nested open tag comes first
      depth++
      pos = nextOpen.index + nextOpen[0].length
    } else {
      // Close tag comes first (or no more open tags)
      depth--
      if (depth === 0) return nextClose.index
      pos = nextClose.index + nextClose[0].length
    }
  }

  return -1
}
