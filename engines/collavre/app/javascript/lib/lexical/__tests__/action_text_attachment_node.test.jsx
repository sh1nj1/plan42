/**
 * @jest-environment jsdom
 */
import { createEditor } from "lexical"
import { ActionTextAttachmentNode, $createActionTextAttachmentNode } from "../action_text_attachment_node"
import { sanitizeAttachmentPayload } from "../attachment_payload"

describe("ActionTextAttachmentNode", () => {
  const parser = new DOMParser()
  let editor

  beforeAll(() => {
    editor = createEditor({
      nodes: [ActionTextAttachmentNode]
    })
  })

  it("exports DOM with canonical wrapper", () => {
    const payload = sanitizeAttachmentPayload({
      sgid: "abc",
      url: "/blob",
      filename: "image.png",
      contentType: "image/png",
      filesize: 2048,
      previewable: true,
      width: 640,
      height: 360,
      caption: "Screenshot"
    })

    let element
    editor.update(() => {
      const node = $createActionTextAttachmentNode(payload)
      element = node.exportDOM().element
    })

    expect(element.tagName).toBe("ACTION-TEXT-ATTACHMENT")
    expect(element.getAttribute("filename")).toBe("image.png")
    const figure = element.querySelector("figure.attachment")
    expect(figure).not.toBeNull()
    expect(figure.getAttribute("data-trix-attachment")).toContain("\"filename\":\"image.png\"")
  })

  it("imports from figure when wrapper missing", () => {
    const html = `
      <figure class="attachment attachment--preview attachment--png" data-trix-content-type="image/png"
        data-trix-attachment='{"sgid":"xyz","filename":"img.png","contentType":"image/png","filesize":1024,"previewable":true,"url":"/blob/xyz"}'>
        <img src="/blob/xyz" alt="img.png" data-width="400" data-height="300">
      </figure>
    `
    const figure = parser.parseFromString(html, "text/html").body.firstElementChild

    let exported
    editor.update(() => {
      const handler = ActionTextAttachmentNode.importDOM().figure(figure)
      const conversion = handler?.conversion(figure)
      const node = conversion?.node
      exported = node.exportDOM().element
    })

    expect(exported?.getAttribute("url")).toBe("/blob/xyz")
  })

  it("applies upload result", () => {
    let payload
    editor.update(() => {
      const node = $createActionTextAttachmentNode({
        filename: "upload.png",
        contentType: "image/png",
        filesize: 100,
        previewable: true,
        status: "uploading"
      })
      node.applyUploadResult({
        sgid: "sgid123",
        url: "/blob/upload",
        filename: "upload.png",
        contentType: "image/png",
        filesize: 4096
      })
      payload = node.getPayload()
    })

    expect(payload).toMatchObject({
      sgid: "sgid123",
      url: "/blob/upload",
      status: "ready",
      progress: 100
    })
  })
})
