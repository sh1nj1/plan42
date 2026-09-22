import { jest } from "@jest/globals"
import { createEditor, $getRoot, $getSelection, $createParagraphNode, $createTextNode, DROP_COMMAND, COMMAND_PRIORITY_EDITOR, UNDO_COMMAND, REDO_COMMAND, HISTORY_PUSH_TAG } from "lexical"
import { $generateHtmlFromNodes } from "@lexical/html"
import { createEmptyHistoryState, registerHistory } from "@lexical/history"
import { registerRichText } from "@lexical/rich-text"
import { UploadAnchorNode } from "../upload_anchor_node"
import { registerFileDrop } from "../file_drop"

describe("inline editor file drops", () => {
  let editor
  let upload
  let unregister
  let unregisterRichText

  beforeEach(() => {
    globalThis.DragEvent = class extends Event {}
    globalThis.ClipboardEvent = class extends Event {}
    editor = createEditor({ nodes: [UploadAnchorNode], onError: (error) => { throw error } })
    unregisterRichText = registerRichText(editor)
    upload = jest.fn()
    unregister = registerFileDrop(editor, upload)
  })

  afterEach(() => {
    unregister()
    unregisterRichText()
    editor.setRootElement(null)
    document.body.replaceChildren()
    delete document.caretRangeFromPoint
    delete document.caretPositionFromPoint
  })

  function drop(files) {
    const event = {
      dataTransfer: { files, types: files.length ? ["Files"] : [] },
      preventDefault: jest.fn(),
      stopPropagation: jest.fn()
    }
    editor.dispatchCommand(DROP_COMMAND, event)
    return event
  }

  it("uploads every dropped file before RichTextPlugin consumes the event", () => {
    const files = [new File(["pdf"], "report.pdf"), new File(["text"], "notes.txt")]
    const event = drop(files)
    expect(upload.mock.calls.map(([file]) => file)).toEqual(files)
    expect(event.preventDefault).toHaveBeenCalledTimes(1)
    expect(event.stopPropagation).toHaveBeenCalledTimes(1)
  })

  it("leaves text and creative drops to existing handlers", () => {
    const fallback = jest.fn(() => true)
    const cleanup = editor.registerCommand(DROP_COMMAND, fallback, COMMAND_PRIORITY_EDITOR)
    const event = drop([])
    expect(upload).not.toHaveBeenCalled()
    expect(event.preventDefault).not.toHaveBeenCalled()
    expect(event.stopPropagation).not.toHaveBeenCalled()
    expect(fallback).toHaveBeenCalledWith(event, editor)
    cleanup()
  })

  it("ignores drops without a data transfer", () => {
    editor.dispatchCommand(DROP_COMMAND, {})
    expect(upload).not.toHaveBeenCalled()
  })

  it("removes the upload handler on cleanup", () => {
    unregister()
    drop([new File(["text"], "notes.txt")])
    expect(upload).not.toHaveBeenCalled()
  })

  async function prepareDocument() {
    const root = document.createElement("div")
    root.contentEditable = "true"
    document.body.append(root)
    editor.setRootElement(root)
    editor.update(() => {
      $getRoot().append($createParagraphNode().append($createTextNode("target")),
        $createParagraphNode().append($createTextNode("other")))
      $getRoot().getLastChild().selectEnd()
    }, { discrete: true })
    return root.querySelector("p").firstChild.firstChild
  }

  async function finishUploads() {
    const committed = jest.fn()
    const complete = index => upload.mock.calls[index][1](
      () => $getSelection().insertText(String(index)), committed)
    complete(1)
    expect(committed).not.toHaveBeenCalled()
    complete(0)
    await Promise.resolve()
    await Promise.resolve()
    expect(committed).toHaveBeenCalledTimes(2)
  }

  it.each(["range", "position"])("inserts at the %s drop coordinates after the caret moves", async api => {
    const text = await prepareDocument()
    if (api === "range") {
      const range = document.createRange()
      range.setStart(text, 3)
      range.collapse(true)
      document.caretRangeFromPoint = jest.fn(() => range)
    } else {
      document.caretPositionFromPoint = jest.fn(() => ({ offsetNode: text, offset: 3 }))
    }
    drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
    editor.update(() => $getRoot().getLastChild().selectStart(), { discrete: true })
    await finishUploads()
    editor.getEditorState().read(() => {
      expect($getRoot().getFirstChild().getTextContent()).toBe("tar01get")
      expect($getRoot().getLastChild().getTextContent()).toBe("other")
    })
  })

  it.each(["prefix", "delete", "split"])("tracks the drop boundary during a %s edit", async edit => {
    const text = await prepareDocument()
    document.caretPositionFromPoint = () => ({ offsetNode: text, offset: 3 })
    drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
    editor.update(() => {
      const prefix = $getRoot().getFirstChild().getFirstChild()
      if (edit === "prefix") {
        prefix.selectStart().insertText("PREFIX")
      } else if (edit === "delete") {
        prefix.select(0, 2).removeText()
      } else {
        prefix.select(1, 1).insertParagraph()
      }
    }, { discrete: true })
    await finishUploads()
    editor.getEditorState().read(() => {
      const expected = { prefix: "PREFIXtar01get", delete: "r01get", split: "t\n\nar01get" }
      expect($getRoot().getTextContent()).toBe(expected[edit] + "\n\nother")
      expect(JSON.stringify(editor.getEditorState().toJSON())).not.toContain("upload-anchor")
    })
  })

  it("keeps pending anchors invisible in exported content and through state updates", async () => {
    const text = await prepareDocument()
    document.caretPositionFromPoint = () => ({ offsetNode: text, offset: 3 })
    drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
    await Promise.resolve()
    editor.update(() => {
      const anchor = $getRoot().getFirstChild().getChildren()[1]
      anchor.getWritable()
      expect(anchor.isKeyboardSelectable()).toBe(false)
    }, { discrete: true })
    editor.getEditorState().read(() => {
      expect($getRoot().getTextContent()).toBe("target\n\nother")
      const div = document.createElement("div")
      div.innerHTML = $generateHtmlFromNodes(editor)
      expect(div.textContent).toBe("targetother")
      expect(div.querySelector("p").children).toHaveLength(2)
    })
    const restored = editor.parseEditorState(JSON.stringify(editor.getEditorState().toJSON()))
    restored.read(() => expect($getRoot().getFirstChild().getChildren()[1]).toBeInstanceOf(UploadAnchorNode))
    await finishUploads()
  })

  it("keeps the captured caret when coordinate lookup is unavailable", async () => {
    await prepareDocument()
    drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
    editor.update(() => $getRoot().getFirstChild().selectStart(), { discrete: true })
    await finishUploads()
    editor.getEditorState().read(() => expect($getRoot().getLastChild().getTextContent()).toBe("other01"))
  })

  it("cancels insertion when the captured target was deleted", async () => {
    await prepareDocument()
    drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
    editor.update(() => $getRoot().getLastChild().remove(), { discrete: true })
    await finishUploads()
    editor.getEditorState().read(() => expect($getRoot().getTextContent()).toBe("target"))
  })

  describe("undo history", () => {
    let history
    let cleanupHistory

    beforeEach(() => {
      history = createEmptyHistoryState()
      cleanupHistory = registerHistory(editor, history, 300)
    })
    afterEach(() => cleanupHistory())

    async function prepareDrop() {
      await prepareDocument()
      history.undoStack = []
      editor.update(() => {
        $getRoot().getLastChild().selectEnd().insertText("!")
      }, { tag: HISTORY_PUSH_TAG, discrete: true })
      const text = editor.getRootElement().querySelector("p").firstChild.firstChild
      document.caretPositionFromPoint = () => ({ offsetNode: text, offset: 3 })
      drop([new File(["a"], "a.txt"), new File(["b"], "b.txt")])
      await Promise.resolve()
    }

    async function command(command) {
      editor.dispatchCommand(command)
      await Promise.resolve()
      await Promise.resolve()
    }

    function content() {
      return editor.getEditorState().read(() => $getRoot().getTextContent())
    }

    it("undoes the last visible edit while pending and never moves cancelled attachments", async () => {
      await prepareDrop()
      expect(history.undoStack).toHaveLength(1)
      await command(UNDO_COMMAND)
      expect(content()).toBe("target\n\nother")
      await finishUploads()
      expect(content()).toBe("target\n\nother")
      expect(history.undoStack).toHaveLength(0)
      await command(REDO_COMMAND)
      expect(content()).toBe("target\n\nother!")
      expect(JSON.stringify(editor.getEditorState().toJSON())).not.toContain("upload-anchor")
    })

    it("undoes and redoes completed attachments in one visible step", async () => {
      await prepareDrop()
      await finishUploads()
      expect(content()).toBe("tar01get\n\nother!")
      await command(UNDO_COMMAND)
      expect(content()).toBe("target\n\nother!")
      expect(JSON.stringify(editor.getEditorState().toJSON())).not.toContain("upload-anchor")
      await command(UNDO_COMMAND)
      expect(content()).toBe("target\n\nother")
      await command(REDO_COMMAND)
      await command(REDO_COMMAND)
      expect(content()).toBe("tar01get\n\nother!")
    })

    it("keeps the anchor when undoing a post-drop edit", async () => {
      await prepareDrop()
      editor.update(() => {
        $getRoot().getFirstChild().getFirstChild().selectStart().insertText("PREFIX")
      }, { tag: HISTORY_PUSH_TAG, discrete: true })
      await command(UNDO_COMMAND)
      expect(content()).toBe("target\n\nother!")
      await finishUploads()
      expect(content()).toBe("tar01get\n\nother!")
    })

    it("does not add an undo step when every upload fails synchronously", async () => {
      await prepareDocument()
      const depth = history.undoStack.length
      upload.mockImplementation((_file, complete) => complete(() => {}, () => {}))
      drop([new File(["a"], "a.txt")])
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
      expect(history.undoStack).toHaveLength(depth)
      expect(content()).toBe("target\n\nother")
      expect(JSON.stringify(editor.getEditorState().toJSON())).not.toContain("upload-anchor")
    })
  })

})
