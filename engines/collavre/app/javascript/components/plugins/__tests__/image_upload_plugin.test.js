import { jest } from "@jest/globals"
import React, { act } from "react"
import { createRoot } from "react-dom/client"
import { createEditor, $createParagraphNode, $createTextNode, DROP_COMMAND } from "lexical"

let editor
jest.unstable_mockModule("@lexical/react/LexicalComposerContext", () => ({
  useLexicalComposerContext: () => [editor]
}))
for (const [module, factory] of [["image_node", "$createImageNode"], ["attachment_node", "$createAttachmentNode"], ["video_node", "$createVideoNode"]]) {
  jest.unstable_mockModule(`../../../lib/lexical/${module}`, () => ({
    [factory]: (attributes) => $createParagraphNode().append($createTextNode(attributes.filename || attributes.altText))
  }))
}
const { default: FileUploadPlugin } = await import("../image_upload_plugin")

describe("file upload completion", () => {
  let root
  let container
  let callbacks
  let states

  beforeEach(() => {
    globalThis.IS_REACT_ACT_ENVIRONMENT = true
    container = document.createElement("div")
    document.body.append(container)
    root = createRoot(container)
    editor = createEditor({ onError: error => { throw error } })
    callbacks = []
    states = jest.fn()
    window.ActiveStorage = { DirectUpload: class {
      constructor(file) { this.file = file }
      create(callback) { callbacks.push({ file: this.file, callback }) }
    } }
  })

  afterEach(async () => {
    await act(async () => root.unmount())
    container.remove()
    delete window.ActiveStorage
    jest.restoreAllMocks()
  })

  async function mount(props = {}) {
    await act(async () => root.render(React.createElement(FileUploadPlugin, {
      directUploadUrl: "/direct_uploads",
      blobUrlTemplate: "/blobs/:signed_id/:filename",
      onUploadStateChange: states,
      ...props
    })))
  }

  function drop() {
    editor.dispatchCommand(DROP_COMMAND, {
      dataTransfer: { files: [new File(["one"], "one.txt"), new File(["two"], "two.txt")] },
      preventDefault() {}, stopPropagation() {}
    })
  }

  async function complete(index, error = null) {
    const { file, callback } = callbacks[index]
    await act(async () => callback(error, { signed_id: String(index), filename: file.name }))
  }

  it("stays busy until every upload is committed to editor state", async () => {
    await mount()
    drop()
    expect(states.mock.calls).toEqual([[true], [true]])
    await complete(1)
    expect(states).toHaveBeenLastCalledWith(true)
    await complete(0)
    expect(states.mock.calls).toEqual([[true], [true], [true], [false]])
    expect(JSON.stringify(editor.getEditorState().toJSON())).toContain("one.txt")
    expect(JSON.stringify(editor.getEditorState().toJSON())).toContain("two.txt")
    const json = JSON.stringify(editor.getEditorState().toJSON())
    expect(json.indexOf("one.txt")).toBeLessThan(json.indexOf("two.txt"))
  })

  it.each([0, 1])("releases failed upload %i while waiting for remaining uploads", async failed => {
    jest.spyOn(console, "error").mockImplementation(() => {})
    await mount()
    drop()
    await complete(failed, new Error("Upload failed"))
    expect(states).toHaveBeenLastCalledWith(true)
    await complete(1 - failed)
    expect(states).toHaveBeenLastCalledWith(false)
  })

  it("releases busy state when configuration is missing", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {})
    await mount({ directUploadUrl: null })
    await act(async () => drop())
    expect(callbacks).toHaveLength(0)
    expect(states).toHaveBeenLastCalledWith(false)
  })

  it("supports uploads without a state callback", async () => {
    await mount({ onUploadStateChange: undefined })
    drop()
    await complete(0)
    await complete(1)
    expect(states).not.toHaveBeenCalled()
  })
})
