import { detectCodeLanguage, normalizeFenceLang, DEFAULT_CODE_LANGUAGE } from "../code_languages"

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
