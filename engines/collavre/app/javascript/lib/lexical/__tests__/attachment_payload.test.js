import {
  sanitizeAttachmentPayload,
  attachmentPayloadFromAttachmentElement,
  attachmentPayloadFromFigure,
  attachmentPayloadToHTMLElement,
  canonicalizeAttachmentElements,
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

  it("infers previewable from URL extension", () => {
    const payload = sanitizeAttachmentPayload({
      url: "https://example.com/uploads/photo.JPG",
      contentType: null,
      filename: "photo.JPG",
      previewable: null
    })
    expect(payload.previewable).toBe(true)
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

  it("ignores figure already wrapped by attachment", () => {
    const {element} = attachmentPayloadToHTMLElement({
      sgid: "wrapped",
      url: "/blob/wrapped",
      filename: "wrapped.png",
      contentType: "image/png",
      filesize: 100,
      previewable: true,
      width: 300,
      height: 200
    })
    const figure = element.querySelector("figure.attachment")
    expect(attachmentPayloadFromFigure(figure)).toBeNull()
  })

  it("deduplicates repeated attachments", () => {
    const payload = {
      sgid: "dup",
      url: "/blob/dup",
      filename: "dup.png",
      contentType: "image/png",
      filesize: 256,
      previewable: true
    }
    const canonical = attachmentPayloadToHTMLElement(payload).element.outerHTML
    const html = `<div>${canonical}${canonical}</div>`
    const doc = parser.parseFromString(html, "text/html")

    canonicalizeAttachmentElements(doc.body)

    expect(doc.body.querySelectorAll("action-text-attachment").length).toBe(1)
  })

  it("collapses stray figure siblings into canonical attachments", () => {
    const html = `
      <div>
        <p>
          <action-text-attachment sgid="abc" url="/blob/abc" filename="photo.jpg"
            content-type="image/jpeg" filesize="1024" previewable="true"></action-text-attachment>
        </p>
        <figure class="attachment attachment--preview attachment--jpeg"
          data-trix-attachment='{"sgid":"abc","filename":"photo.jpg","contentType":"image/jpeg","filesize":1024,"previewable":true,"url":"/blob/abc"}'>
          <img src="/blob/abc" alt="photo.jpg">
          <figcaption class="attachment__caption">
            <span class="attachment__name">photo.jpg</span>
            <span class="attachment__size">1 KB</span>
          </figcaption>
        </figure>
      </div>
    `
    const doc = parser.parseFromString(html, "text/html")

    canonicalizeAttachmentElements(doc.body)

    const attachments = doc.body.querySelectorAll("action-text-attachment")
    expect(attachments.length).toBe(1)
    expect(doc.body.querySelector("action-text-attachment > figure.attachment")).toBeNull()
    expect(doc.body.querySelectorAll(":scope > figure.attachment").length).toBe(0)
  })

  it("keeps non-consecutive duplicate payloads", () => {
    const payloadA = attachmentPayloadToHTMLElement({
      sgid: "A",
      url: "/blob/A",
      filename: "a.png",
      contentType: "image/png",
      previewable: true
    }).element.outerHTML
    const payloadB = attachmentPayloadToHTMLElement({
      sgid: "B",
      url: "/blob/B",
      filename: "b.png",
      contentType: "image/png",
      previewable: true
    }).element.outerHTML
    const html = `<div>${payloadA}${payloadB}${payloadA}</div>`
    const doc = parser.parseFromString(html, "text/html")

    canonicalizeAttachmentElements(doc.body)

    expect(doc.body.querySelectorAll("action-text-attachment").length).toBe(3)
  })
})
