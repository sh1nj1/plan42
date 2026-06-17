import { renderMarkdown, renderCommentMarkdown } from "../markdown"

// The renderers run with marked's `breaks: true` so a single newline becomes a
// <br> (GitHub/Slack style), matching the canonical markdown_source which stores
// consecutive rich-editor lines one-per-line instead of separated by a blank line.
describe("renderMarkdown hard breaks", () => {
  it("renders a single newline as <br> within one paragraph", () => {
    const html = renderMarkdown("abc\ndef")
    expect(html).toContain("<br")
    expect((html.match(/<p>/g) || []).length).toBe(1)
  })

  it("keeps a blank line as a paragraph break", () => {
    const html = renderMarkdown("abc\n\ndef")
    expect((html.match(/<p>/g) || []).length).toBe(2)
  })
})

describe("renderCommentMarkdown hard breaks", () => {
  it("renders a single newline in a comment as <br>", () => {
    expect(renderCommentMarkdown("line1\nline2")).toContain("<br")
  })
})

// The optimistic row preview (creative_row_editor) derives nested-list HTML from
// the canonical Markdown via this renderer instead of Lexical's HTML projection,
// which nests lists as a sibling empty <li> that renders an extra blank bullet.
// Guard that the Markdown render produces a proper child <ul> with no empty <li>.
describe("renderMarkdown nested list (Tab-indent preview)", () => {
  it("nests an indented item as a child <ul> with no empty wrapper <li>", () => {
    const html = renderMarkdown("- a\n    - b")
    expect(html).toMatch(
      /<ul>[\s\S]*<li>a[\s\S]*<ul>[\s\S]*<li>b<\/li>[\s\S]*<\/ul>[\s\S]*<\/li>[\s\S]*<\/ul>/
    )
    expect(html).not.toMatch(/<li>\s*<ul>/)
  })
})
