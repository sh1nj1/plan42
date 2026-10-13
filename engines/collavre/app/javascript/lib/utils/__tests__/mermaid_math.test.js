import katex from "katex"
import mermaid from "mermaid"

describe("Mermaid math dependency", () => {
  it("parses math labels and renders mathematical expressions", async () => {
    mermaid.initialize({ startOnLoad: false, securityLevel: "strict" })
    expect(await mermaid.parse('graph TD\n A["$$E=mc^2$$"] --> B')).toBeTruthy()
    expect(katex.renderToString("E=mc^2")).toContain('class="katex"')
  })

  it("does not enable unsafe links through inherited trust settings", () => {
    const original = Object.getOwnPropertyDescriptor(Object.prototype, "trust")
    try {
      Object.defineProperty(Object.prototype, "trust", { value: true, writable: true, configurable: true })
      const html = katex.renderToString(String.raw`\href{javascript:alert(1)}{click}`, {
        throwOnError: false
      })
      expect(html).not.toContain('href="javascript:')
    } finally {
      if (original) Object.defineProperty(Object.prototype, "trust", original)
      else delete Object.prototype.trust
    }
  })
})
