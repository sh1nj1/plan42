import { addTableDownloadButtons } from "../table_download"

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
