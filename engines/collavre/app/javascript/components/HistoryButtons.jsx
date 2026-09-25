import { UNDO_COMMAND, REDO_COMMAND } from "lexical"

export default function HistoryButtons({ editor, canUndo, canRedo }) {
  return (
    <>
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => editor.dispatchCommand(UNDO_COMMAND, undefined)}
        disabled={!canUndo}
        title="Undo (⌘/Ctrl+Z)"
        aria-label="Undo">
        ↩
      </button>
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={() => editor.dispatchCommand(REDO_COMMAND, undefined)}
        disabled={!canRedo}
        title="Redo (⇧⌘/Ctrl+Z)"
        aria-label="Redo">
        ↪
      </button>
    </>
  )
}

