import {
  sanitizeAttachmentPayload,
  attachmentPayloadFromAttachmentElement,
  attachmentPayloadFromFigure,
  attachmentPayloadToHTMLElement,
  formatFileSize
} from "../attachment_payload"

describe("attachment_payload helpers", () => {
  const parser = new DOMParser()

  it("normalizes and sanitizes raw payload", () => {
    const raw = {
      sgid: null,
      url: "/blob",
      filename: " Example.PNG ",
      contentType: "image/png",
      filesize: "2048",
      caption: "Example.PNG 2 KB",
      previewable: "true",
      width: "640px",
      height: "360px"
    }

    const payload = sanitizeAttachmentPayload(raw)
    expect(payload).toMatchObject({
      url: "/blob",
      filename: "Example.PNG",
      contentType: "image/png",
      filesize: 2048,
      previewable: true,
      width: 640,
      height: 360,
      caption: ""
    })
    expect(formatFileSize(payload.filesize)).toBe("2 KB")
  })

  it("parses canonical attachment element", () => {
    const html = `
      <action-text-attachment sgid="abc" url="/blob" filename="file.png" 
        content-type="image/png" filesize="12345" previewable="true"
        data-width="640" data-height="360"></action-text-attachment>
    `
    const element = parser.parseFromString(html, "text/html").body.firstElementChild
    const payload = attachmentPayloadFromAttachmentElement(element)
    expect(payload).toMatchObject({
      sgid: "abc",
      url: "/blob",
      filename: "file.png",
      contentType: "image/png",
      filesize: 12345,
      previewable: true,
      width: 640,
      height: 360
    })
  })

  it("parses figure attachment", () => {
    const html = `
      <figure class="attachment attachment--preview attachment--png" data-trix-content-type="image/png"
        data-trix-attachment='{"sgid":"xyz","filename":"img.png","contentType":"image/png","filesize":1024,"previewable":true,"url":"/blob/xyz"}'>
        <img src="/blob/xyz" alt="img.png" data-width="400" data-height="300">
        <figcaption class="attachment__caption">
          <span class="attachment__name">img.png</span>
          <span class="attachment__size">1 KB</span>
        </figcaption>
      </figure>
    `
    const element = parser.parseFromString(html, "text/html").body.firstElementChild
    const payload = attachmentPayloadFromFigure(element)
    expect(payload).toMatchObject({
      sgid: "xyz",
      filename: "img.png",
      url: "/blob/xyz",
      previewable: true,
      filesize: 1024
    })
  })

  it("serializes payload back to canonical HTML", () => {
    const {element} = attachmentPayloadToHTMLElement({
      sgid: "xyz",
      url: "/blob",
      filename: "file.csv",
      contentType: "text/csv",
      filesize: 512,
      caption: "Report",
      previewable: false,
      width: null,
      height: null
    })

    expect(element.tagName).toBe("ACTION-TEXT-ATTACHMENT")
    expect(element.getAttribute("filename")).toBe("file.csv")
    const figure = element.querySelector("figure.attachment")
    expect(figure).not.toBeNull()
    expect(figure.getAttribute("data-trix-attachment")).toContain("\"filename\":\"file.csv\"")
  })
})
