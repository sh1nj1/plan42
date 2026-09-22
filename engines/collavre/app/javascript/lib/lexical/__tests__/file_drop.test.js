import { jest } from "@jest/globals"
import { createEditor, DROP_COMMAND, COMMAND_PRIORITY_EDITOR } from "lexical"
import { registerRichText } from "@lexical/rich-text"
import { registerFileDrop } from "../file_drop"

describe("inline editor file drops", () => {
  let editor
  let upload
  let unregister
  let unregisterRichText

  beforeEach(() => {
    globalThis.DragEvent = class extends Event {}
    globalThis.ClipboardEvent = class extends Event {}
    editor = createEditor({ onError: (error) => { throw error } })
    unregisterRichText = registerRichText(editor)
    upload = jest.fn()
    unregister = registerFileDrop(editor, upload)
  })

  afterEach(() => {
    unregister()
    unregisterRichText()
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
    expect(upload.mock.calls).toEqual(files.map(file => [file]))
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
})
