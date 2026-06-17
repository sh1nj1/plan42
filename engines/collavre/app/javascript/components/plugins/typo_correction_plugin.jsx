// Typo correction inside the Lexical inline editor (Phase 2).
//
// Mirrors the chat composer (Phase 1) but for rich text. The highlight is a
// *volatile* DOM overlay: an absolutely-positioned layer over the contenteditable
// whose marks are drawn from live DOM Range rectangles. The editor state is only
// ever mutated to perform a *real* correction (which legitimately belongs in the
// markdown) — never to hold a highlight — so markdown-canonical storage never
// sees a mark. This is the headline safety guarantee of Phase 2.
//
// Two highlight states (shape + colour, for colour-blind safety):
//   - auto-applied (confidence >= threshold): faint straight underline
//   - candidate    (below threshold):         wavy dotted underline (needs decision)
//
// Correctable text is the editor's plain text with code blocks, inline-code, and
// link text excluded (those are protected, matching the server's skip ranges).
// A span that straddles multiple text nodes (e.g. a bolded middle letter) can't
// be cleanly rewritten in place, so it is skipped rather than mis-edited.

import { useEffect } from "react"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  $getRoot,
  $getNodeByKey,
  $isTextNode,
  $isElementNode
} from "lexical"
import csrfFetch from "../../lib/api/csrf_fetch"
import { TypoPopup } from "../../lib/typo_popup"
import { buildFlatText, mapRange } from "../../lib/lexical_typo_text"
import {
  detectDevice,
  shouldRun,
  anchorEdits,
  partitionByThreshold
} from "../../lib/typo_correction"

const DEBOUNCE_MS = 600
const PRINTABLE_KEYDOWN_TTL_MS = 50

export class EditorTypoController {
  constructor(editor, { settings, endpoint, labels, getVoiceActive }) {
    this.editor = editor
    this.settings = settings
    this.endpoint = endpoint
    this.getVoiceActive = getVoiceActive || (() => false)

    // marks currently painted: {original, suggestion, currentValue, confidence,
    // state, _order}. `_order` is the last-known flat offset, used only to keep a
    // stable document order when re-anchoring duplicates by value.
    this.marks = []
    this.lastPrintableKeydownAt = null
    this.lastInputAt = null
    this.debounceTimer = null
    this.requestSeq = 0
    this.suppressNextDetect = false
    this.disposed = false

    this.popup = new TypoPopup({
      labels,
      onChoose: (value, edit) => this._applyChoice(value, edit)
    })

    this.root = editor.getRootElement()
    this._buildOverlay()
    this._bind()
  }

  _buildOverlay() {
    this.overlay = document.createElement("div")
    this.overlay.className = "typo-editor-overlay"
    this.overlay.setAttribute("aria-hidden", "true")
    // The overlay sits in the contenteditable's offset parent and is positioned
    // to cover it; CSS makes the layer pointer-events:none so typing/selection
    // pass through, while individual marks re-enable pointer events.
    const host = this.root.parentElement || this.root
    host.appendChild(this.overlay)
    this._positionOverlay()
  }

  _positionOverlay() {
    if (!this.overlay || !this.root) return
    const host = this.overlay.offsetParent || this.root.parentElement
    if (!host) return
    const hostRect = host.getBoundingClientRect()
    const r = this.root.getBoundingClientRect()
    this.overlay.style.top = `${r.top - hostRect.top}px`
    this.overlay.style.left = `${r.left - hostRect.left}px`
    this.overlay.style.width = `${r.width}px`
    this.overlay.style.height = `${r.height}px`
  }

  _bind() {
    this._onKeydown = (event) => {
      if (event.key && event.key.length === 1 && !event.ctrlKey && !event.metaKey) {
        this.lastPrintableKeydownAt = performance.now()
      }
    }
    // The contenteditable fires a native `input` on every text mutation. Stamp
    // the time *now* (while the keydown→input link is fresh) so device
    // classification after the debounce isn't misread as a soft keyboard.
    this._onInput = () => {
      this.lastInputAt = performance.now()
      if (this.suppressNextDetect) {
        this.suppressNextDetect = false
        this._repaint()
        return
      }
      this._scheduleDetect()
    }
    this._onScrollOrResize = () => {
      if (this._rafPending) return
      this._rafPending = true
      requestAnimationFrame(() => {
        this._rafPending = false
        this._positionOverlay()
        this._repaint()
      })
    }

    this.root.addEventListener("keydown", this._onKeydown)
    this.root.addEventListener("input", this._onInput)
    this.root.addEventListener("scroll", this._onScrollOrResize)
    window.addEventListener("resize", this._onScrollOrResize)

    // Re-anchor and reposition the overlay whenever the document changes by any
    // route (typing, toolbar, undo) so marks track the text they cover.
    this._unregisterUpdate = this.editor.registerUpdateListener(() => {
      if (this.disposed) return
      this._positionOverlay()
      this._repaint()
    })
  }

  destroy() {
    this.disposed = true
    clearTimeout(this.debounceTimer)
    this.requestSeq++
    this.root.removeEventListener("keydown", this._onKeydown)
    this.root.removeEventListener("input", this._onInput)
    this.root.removeEventListener("scroll", this._onScrollOrResize)
    window.removeEventListener("resize", this._onScrollOrResize)
    this._unregisterUpdate?.()
    this.popup?.destroy()
    this.overlay?.remove()
    this.overlay = null
  }

  _currentDevice() {
    return detectDevice({
      voiceActive: !!this.getVoiceActive(),
      lastPrintableKeydownAt: this.lastPrintableKeydownAt,
      inputAt: this.lastInputAt
    })
  }

  _scheduleDetect() {
    clearTimeout(this.debounceTimer)
    this.debounceTimer = setTimeout(() => this._detect(), DEBOUNCE_MS)
  }

  // Flatten the correctable text nodes (in document order) into segments the
  // server can scan and we can map back. Code blocks, inline-code, and link text
  // are excluded — they are protected, and excluding them keeps offsets clean.
  _collectSegments() {
    const segments = []
    this.editor.getEditorState().read(() => {
      const blocks = $getRoot().getChildren()
      blocks.forEach((block, index) => {
        if (index > 0) segments.push({ key: null, text: "\n" })
        if (block.getType() === "code") return
        const walk = (node) => {
          if ($isTextNode(node)) {
            if (node.hasFormat && node.hasFormat("code")) return
            const text = node.getTextContent()
            if (text) segments.push({ key: node.getKey(), text })
            return
          }
          if (typeof node.getType === "function" && node.getType() === "link") return
          if ($isElementNode(node)) node.getChildren().forEach(walk)
        }
        walk(block)
      })
    })
    return segments
  }

  async _detect() {
    if (this.disposed) return
    const device = this._currentDevice()
    if (this.lastPrintableKeydownAt != null && performance.now() - this.lastPrintableKeydownAt > PRINTABLE_KEYDOWN_TTL_MS) {
      this.lastPrintableKeydownAt = null
    }
    if (!shouldRun(this.settings, { device, location: "editor" })) return

    const { text } = buildFlatText(this._collectSegments())
    if (!text.trim()) { this._clear(); return }

    const seq = ++this.requestSeq
    let payload
    try {
      const res = await csrfFetch(this.endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ text, device, location: "editor" })
      })
      if (!res.ok) return
      payload = await res.json()
    } catch {
      return
    }
    if (this.disposed || seq !== this.requestSeq) return
    // The text may have changed while the request was in flight; only act if the
    // edits still anchor to the *current* editor text.
    const current = buildFlatText(this._collectSegments()).text
    if (current !== text) return

    this._applyResult(text, payload)
  }

  _applyResult(sentText, { edits = [], threshold = 80 } = {}) {
    const anchored = anchorEdits(sentText, edits)
    const { autoApplied, candidates } = partitionByThreshold(anchored, threshold)

    // Apply the high-confidence edits to the editor in one history-grouped
    // update. Single-text-node spans only; cross-node spans are skipped (can't be
    // rewritten in place without clobbering formatting).
    const applied = []
    if (autoApplied.length) {
      this.editor.update(() => {
        // Re-map against the *current* flat text/segments inside the update so
        // node keys and offsets are consistent with what we mutate.
        const { map } = buildFlatText(this._collectSegments())
        // Apply right-to-left so earlier offsets stay valid as we splice.
        const ordered = [...autoApplied].sort((a, b) => b.start - a.start)
        for (const edit of ordered) {
          const pieces = mapRange(map, edit.start, edit.end)
          if (pieces.length !== 1) continue // cross-node span — skip
          const { key, localStart, localEnd } = pieces[0]
          const node = $getNodeByKey(key)
          if (!$isTextNode(node)) continue
          const t = node.getTextContent()
          if (t.slice(localStart, localEnd) !== edit.original) continue
          node.setTextContent(t.slice(0, localStart) + edit.suggestion + t.slice(localEnd))
          applied.push(edit)
        }
      })
    }

    // Build this round's marks. Applied edits get an undo affordance; candidates
    // wait for a decision. `_order` keeps a stable left-to-right order for
    // anchoring duplicates by value on repaint.
    const incoming = [
      ...applied.map((e) => ({
        original: e.original, suggestion: e.suggestion, currentValue: e.suggestion,
        confidence: e.confidence, state: "applied", _order: e.start
      })),
      ...candidates.map((e) => ({
        original: e.original, suggestion: e.suggestion, currentValue: e.original,
        confidence: e.confidence, state: "candidate", _order: e.start
      }))
    ]

    // Carry forward earlier marks whose word still exists in the live text (the
    // server is stateless and never re-reports an already-corrected word, so
    // without this each round would wipe prior marks). repaint() re-anchors every
    // mark left-to-right with a cursor, so a survivor whose only occurrence is
    // claimed by an incoming mark of the same value simply fails to re-anchor and
    // is dropped — no explicit de-dup needed here.
    const { text: liveText } = buildFlatText(this._collectSegments())
    const survivors = this.marks.filter((m) => liveText.includes(m.currentValue))

    this.marks = [...survivors, ...incoming]
    this._repaint()
  }

  _clear() {
    this.marks = []
    this._repaint()
  }

  // Re-anchor every mark against the current flat text by value (advancing a
  // cursor so repeated words bind to distinct occurrences), drop the ones whose
  // text the user has since edited away, then draw a rect over each survivor.
  _repaint() {
    if (this.disposed || !this.overlay) return
    const { text, map } = buildFlatText(this._collectSegments())

    const ordered = [...this.marks].sort((a, b) => (a._order ?? 0) - (b._order ?? 0))
    let cursor = 0
    const anchored = []
    for (const m of ordered) {
      const idx = text.indexOf(m.currentValue, cursor)
      if (idx === -1) continue
      anchored.push({ ...m, start: idx, end: idx + m.currentValue.length, _order: idx })
      cursor = idx + m.currentValue.length
    }
    this.marks = anchored

    this.overlay.textContent = ""
    if (anchored.length === 0) return

    const overlayRect = this.overlay.getBoundingClientRect()
    anchored.forEach((mark) => {
      this._paintMark(mark, map, overlayRect)
    })
  }

  _paintMark(mark, map, overlayRect) {
    const pieces = mapRange(map, mark.start, mark.end)
    if (pieces.length === 0) return
    for (const piece of pieces) {
      const el = this.editor.getElementByKey(piece.key)
      const textNode = el?.firstChild
      if (!textNode || textNode.nodeType !== Node.TEXT_NODE) continue
      const len = textNode.textContent.length
      const s = Math.min(piece.localStart, len)
      const e = Math.min(piece.localEnd, len)
      if (e <= s) continue
      const range = document.createRange()
      range.setStart(textNode, s)
      range.setEnd(textNode, e)
      const rects = typeof range.getClientRects === "function" ? range.getClientRects() : []
      for (const rect of rects) {
        const span = document.createElement("span")
        span.className = mark.state === "applied"
          ? "typo-mark typo-mark-applied"
          : "typo-mark typo-mark-candidate"
        span.style.top = `${rect.top - overlayRect.top}px`
        span.style.left = `${rect.left - overlayRect.left}px`
        span.style.width = `${rect.width}px`
        span.style.height = `${rect.height}px`
        span.addEventListener("mousedown", (event) => {
          event.preventDefault()
          this.popup.open(mark, rect, { coarsePointer: this._isCoarsePointer() })
        })
        this.overlay.appendChild(span)
      }
    }
  }

  _isCoarsePointer() {
    return typeof window.matchMedia === "function" && window.matchMedia("(pointer: coarse)").matches
  }

  // Apply the value chosen in the combobox (the popup has already closed).
  // Replacing rewrites the word in its text node; choosing the current value
  // ("keep") just drops the mark.
  _applyChoice(value, mark) {
    if (mark == null || value == null) return
    const replacement = String(value)
    if (replacement === mark.currentValue) {
      this.marks = this.marks.filter((m) => m !== mark)
      this._repaint()
      return
    }

    this.editor.update(() => {
      const { text, map } = buildFlatText(this._collectSegments())
      // The mark was anchored against this same flat text on the last repaint and
      // nothing edits the document while the popup is open, so mark.start is
      // exact; fall back to a forward search if the text somehow shifted.
      let start = mark.start
      if (typeof start !== "number" || text.slice(start, start + mark.currentValue.length) !== mark.currentValue) {
        start = text.indexOf(mark.currentValue)
      }
      if (start === -1) return
      const pieces = mapRange(map, start, start + mark.currentValue.length)
      if (pieces.length !== 1) return
      const { key, localStart, localEnd } = pieces[0]
      const node = $getNodeByKey(key)
      if (!$isTextNode(node)) return
      const t = node.getTextContent()
      node.setTextContent(t.slice(0, localStart) + replacement + t.slice(localEnd))
    })

    // The word is now user-confirmed; drop its mark. The update listener repaints.
    this.marks = this.marks.filter((m) => m !== mark)
    this.suppressNextDetect = true
  }
}

export default function TypoCorrectionPlugin({ settings, endpoint, labels, getVoiceActive }) {
  const [editor] = useLexicalComposerContext()

  useEffect(() => {
    if (!settings || settings.enabled !== true) return undefined
    const root = editor.getRootElement()
    if (!root) return undefined

    const controller = new EditorTypoController(editor, { settings, endpoint, labels, getVoiceActive })
    return () => controller.destroy()
  }, [editor, settings, endpoint, labels, getVoiceActive])

  return null
}
