// Pure offset↔node mapping for typo correction inside the Lexical editor
// (Phase 2). Framework-free so it can be unit-tested without a DOM.
//
// The editor's content is rich (paragraphs, lists, code, links). For typo
// correction we flatten the *correctable* text nodes into a single string with
// stable global offsets, send that to the server, and map the returned spans
// back to specific Lexical text nodes. The caller builds the segment list from
// the editor state (excluding code/link text, which is protected), and uses the
// returned map to paint a *volatile* DOM overlay — the editor state is never
// mutated to hold a highlight, so markdown-canonical storage never sees one.

// Build the flat text and an offset map from an ordered segment list.
//
// Each segment is `{ key, text }`. A segment with a `key` is a real Lexical text
// node (mappable back to the DOM); a keyless segment (e.g. a block separator we
// insert between paragraphs so words don't merge across blocks) advances the
// offset but is not mappable. Returns `{ text, map }` where `map` is the list of
// keyed segments with their `[start, end)` flat offsets.
export function buildFlatText(segments = []) {
  let text = ''
  const map = []
  let offset = 0
  for (const seg of segments) {
    if (!seg || typeof seg.text !== 'string') continue
    const start = offset
    text += seg.text
    offset += seg.text.length
    if (seg.key != null) {
      map.push({ key: seg.key, start, end: offset })
    }
  }
  return { text, map }
}

// Find the keyed segment containing a flat `offset` and its node-local offset.
// Offsets sit on the half-open interval `[start, end)`; a position exactly at a
// segment's end is reported in the *next* keyed segment when one abuts it (so a
// caret between two nodes binds to the node it's entering), else clamped to the
// last segment's end. Returns null if no keyed segment covers it.
export function locateOffset(map = [], offset) {
  if (!Array.isArray(map) || map.length === 0) return null
  for (let i = 0; i < map.length; i++) {
    const seg = map[i]
    if (offset >= seg.start && offset < seg.end) {
      return { key: seg.key, localOffset: offset - seg.start }
    }
    // Position exactly at this segment's end: bind to the next abutting segment
    // if there is one, otherwise to this segment's end.
    if (offset === seg.end) {
      const next = map[i + 1]
      if (next && next.start === seg.end) {
        return { key: next.key, localOffset: 0 }
      }
      return { key: seg.key, localOffset: seg.end - seg.start }
    }
  }
  return null
}

// Map a flat `[start, end)` range onto the keyed segments it covers, returning
// one `{ key, localStart, localEnd }` sub-range per intersected segment. A typo
// span usually lives in a single text node, but rich formatting (e.g. a bolded
// middle letter) can split it across nodes — each piece is returned so the
// overlay can draw a rect over every fragment. Sub-ranges that would be empty
// are dropped.
export function mapRange(map = [], start, end) {
  if (!Array.isArray(map) || end <= start) return []
  const out = []
  for (const seg of map) {
    const lo = Math.max(start, seg.start)
    const hi = Math.min(end, seg.end)
    if (hi <= lo) continue
    out.push({ key: seg.key, localStart: lo - seg.start, localEnd: hi - seg.start })
  }
  return out
}
