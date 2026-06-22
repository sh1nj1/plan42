import { addTableDownloadButtons, addCreativeTableDownloadButtons } from "../table_download"

// addTableDownloadButtons is the single shared utility used to attach CSV/Excel
// download toolbars to rendered markdown tables. It must be container-agnostic so
// chat comments (.comment-content) and creative descriptions (.creative-content)
// get an identical toolbar — that is what "unify creative tables with chat
// tables" relies on.
function makeTable() {
  const el = document.createElement("div")
  el.innerHTML =
    "<table><thead><tr><th>이름</th><th>점수</th></tr></thead>" +
    "<tbody><tr><td>철수</td><td>90</td></tr></tbody></table>"
  return el
}

describe("addTableDownloadButtons (shared comment + creative path)", () => {
  it("wraps a table in any container and adds CSV + Excel buttons", () => {
    const container = makeTable()
    container.className = "creative-content"

    addTableDownloadButtons(container)

    const wrapper = container.querySelector(".table-download-wrapper")
    expect(wrapper).not.toBeNull()
    const buttons = wrapper.querySelectorAll(".table-download-btn")
    expect(buttons.length).toBe(2)
    const labels = Array.from(buttons).map((b) => b.textContent)
    expect(labels.some((l) => l.includes("CSV"))).toBe(true)
    expect(labels.some((l) => l.includes("Excel"))).toBe(true)
    // The table itself is moved inside the wrapper (toolbar precedes it).
    expect(wrapper.querySelector("table")).not.toBeNull()
  })

  it("is idempotent — repeated calls (Lit re-renders) do not double-wrap", () => {
    const container = makeTable()
    container.className = "creative-content"

    addTableDownloadButtons(container)
    addTableDownloadButtons(container)
    addTableDownloadButtons(container)

    expect(container.querySelectorAll(".table-download-wrapper").length).toBe(1)
    expect(container.querySelectorAll(".table-download-btn").length).toBe(2)
  })

  it("does nothing when there is no table", () => {
    const container = document.createElement("div")
    container.className = "creative-content"
    container.innerHTML = "<p>no table here</p>"

    addTableDownloadButtons(container)

    expect(container.querySelector(".table-download-wrapper")).toBeNull()
  })
})

describe("addCreativeTableDownloadButtons (row-scoped)", () => {
  const tableHtml =
    "<table><thead><tr><th>이름</th></tr></thead><tbody><tr><td>철수</td></tr></tbody></table>"

  // Mirrors the live DOM: the inline editor is appended into .creative-tree as a
  // sibling of the display areas, so a whole-subtree scan (the old bug) would
  // move its <table> into a wrapper and corrupt in-progress edits.
  function makeRow() {
    const row = document.createElement("div")
    row.innerHTML =
      '<div class="creative-tree">' +
      `<div class="creative-row"><div class="creative-content">${tableHtml}</div></div>` +
      `<div id="inline-edit-form"><div data-lexical-editor-root>${tableHtml}</div>` +
      `<div id="markdown-preview">${tableHtml}</div></div>` +
      "</div>"
    return row
  }

  it("wraps display-area tables but never the inline editor's tables", () => {
    const row = makeRow()

    addCreativeTableDownloadButtons(row)

    expect(row.querySelector(".creative-content .table-download-wrapper")).not.toBeNull()
    expect(row.querySelector("#inline-edit-form .table-download-wrapper")).toBeNull()
    expect(row.querySelector("#markdown-preview .table-download-wrapper")).toBeNull()
  })

  it("also wraps title-content tables", () => {
    const row = document.createElement("div")
    row.innerHTML = `<div class="creative-title-content">${tableHtml}</div>`

    addCreativeTableDownloadButtons(row)

    expect(row.querySelector(".creative-title-content .table-download-wrapper")).not.toBeNull()
  })
})
