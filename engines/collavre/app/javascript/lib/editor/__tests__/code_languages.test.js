import { detectCodeLanguage, normalizeFenceLang, bridgeCodeFenceLanguages, DEFAULT_CODE_LANGUAGE } from "../code_languages"

const RUBY = `# frozen_string_literal: true
module CollavreCompat
  module_function

  def call(receiver, method_name, *args, **kwargs)
    params = receiver.method(method_name).parameters
    receiver.public_send(method_name, *args, **kwargs)
  end
end`

describe("normalizeFenceLang", () => {
  it("canonicalizes aliases", () => {
    expect(normalizeFenceLang("rb")).toBe("ruby")
    expect(normalizeFenceLang("YML")).toBe("yaml")
    expect(normalizeFenceLang("sh")).toBe("bash")
    expect(normalizeFenceLang("html")).toBe("markup")
  })

  it("returns empty for missing or unsafe input", () => {
    expect(normalizeFenceLang("")).toBe("")
    expect(normalizeFenceLang(null)).toBe("")
    expect(normalizeFenceLang("not a lang")).toBe("")
  })
})

describe("detectCodeLanguage", () => {
  it("honors an explicit, non-default fence language without re-detecting", () => {
    // Even though this looks like Ruby, an explicit `python` fence is respected.
    expect(detectCodeLanguage(RUBY, "python")).toBe("python")
    expect(detectCodeLanguage(RUBY, "rb")).toBe("ruby")
  })

  it("re-detects Ruby content stuck on the javascript default", () => {
    expect(detectCodeLanguage(RUBY, "javascript")).toBe("ruby")
    expect(detectCodeLanguage(RUBY, "")).toBe("ruby")
    expect(detectCodeLanguage(RUBY, undefined)).toBe("ruby")
  })

  it("keeps real JavaScript as javascript (detection does not beat JS for JS)", () => {
    const js = "function add(a, b) {\n  const total = a + b\n  return total\n}"
    expect(detectCodeLanguage(js, "javascript")).toBe("javascript")
  })

  it("does not detect from a too-short snippet", () => {
    expect(detectCodeLanguage("x = 1", "javascript")).toBe("javascript")
    expect(detectCodeLanguage("x = 1", "")).toBe("")
  })

  it("exposes the javascript default constant", () => {
    expect(DEFAULT_CODE_LANGUAGE).toBe("javascript")
  })
})

describe("bridgeCodeFenceLanguages", () => {
  function parse(html) {
    const doc = new DOMParser().parseFromString(html, "text/html")
    return doc.body
  }

  it("bridges commonmarker's <pre lang> to data-language", () => {
    const c = parse('<pre lang="ruby"><code>x = 1</code></pre>')
    bridgeCodeFenceLanguages(c)
    expect(c.querySelector("pre").getAttribute("data-language")).toBe("ruby")
  })

  it("bridges marked's <code class=\"language-X\"> to data-language on <pre>", () => {
    // This is the markdown→rich toggle case: renderMarkdown emits the fence
    // language on the <code>, not the <pre>, so it was dropped on reopen.
    const c = parse('<pre><code class="hljs language-ruby">x = 1</code></pre>')
    bridgeCodeFenceLanguages(c)
    expect(c.querySelector("pre").getAttribute("data-language")).toBe("ruby")
  })

  it("canonicalizes aliases while bridging", () => {
    const c = parse('<pre><code class="language-rb">x = 1</code></pre>')
    bridgeCodeFenceLanguages(c)
    expect(c.querySelector("pre").getAttribute("data-language")).toBe("ruby")
  })

  it("does not overwrite an existing data-language", () => {
    const c = parse('<pre lang="python" data-language="ruby"><code>x = 1</code></pre>')
    bridgeCodeFenceLanguages(c)
    expect(c.querySelector("pre").getAttribute("data-language")).toBe("ruby")
  })

  it("leaves a language-less block alone (detection handles it later)", () => {
    const c = parse("<pre><code>x = 1</code></pre>")
    bridgeCodeFenceLanguages(c)
    expect(c.querySelector("pre").hasAttribute("data-language")).toBe(false)
  })
})
