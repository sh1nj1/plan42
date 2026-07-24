# Creative Table Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GFM-table editing to the creative Lexical editor — a toolbar insert button plus cell-boundary "+" buttons to add rows/columns — that round-trips losslessly through the markdown-canonical storage format.

**Architecture:** Register `@lexical/table` nodes in the existing `InlineLexicalEditor.jsx`. Tables round-trip through two paths that are *already* table-aware: (1) **markdown_source** (canonical) via a ported `TABLE` markdown ElementTransformer added to `MARKDOWN_TRANSFORMERS` — it both exports Lexical tables → GFM pipe tables and imports them back; (2) **description_raw_html** (the reopen path) via `$generateHtmlFromNodes` → `minimize_html` (which already keeps `TABLE/THEAD/TBODY/TR/TD/TH`) → `$generateNodesFromDOM` (which uses `@lexical/table`'s `importDOM`). Display rendering already works: `marked` emits GFM tables by default, DOMPurify allows table tags, and `addTableDownloadButtons` already decorates rendered tables. UI: mount the upstream `TablePlugin` for cell navigation, add a toolbar button dispatching `INSERT_TABLE_COMMAND`, and port the playground's `TableHoverActionsPlugin` (the cell-boundary "+" buttons) to `.jsx`.

**Tech Stack:** React, Lexical 0.38.2, `@lexical/table` 0.38.2, `@lexical/markdown`, esbuild, Jest (native ESM), Rails i18n (en/ko).

## Global Constraints

- **Markdown-canonical storage (PR #1313):** every editor feature MUST round-trip through `markdown_serialize.js` → GFM. A table that doesn't serialize to a GFM pipe table is silently lost on save. This is the hardest constraint.
- **`.jsx` not `.tsx`:** the editor codebase is plain JSX. The stale `feat/lexical-editor-table` branch (TS, pre-#1313) is reference-only — do NOT reuse its files.
- **i18n required (en + ko):** all user-facing text (toolbar tooltip/aria-label) must use i18n. No hardcoded English in UI.
- **Engine dependency direction:** all changes live in the `collavre` core engine (`engines/collavre/app/javascript`). No `collavre_*` plugin coupling.
- **Real call site is `InlineLexicalEditor.jsx`:** markdown serialization is invoked there via `$convertToMarkdownString(MARKDOWN_TRANSFORMERS)` (line 934) and `lexicalToMarkdown` is a test-only wrapper. Adding a transformer to the exported `MARKDOWN_TRANSFORMERS` array covers both. Verify with a bundle grep (null bytes present — use `grep -ac`).
- **esbuild bundle is gitignored:** after JS changes, `npm run build` then grep the built bundle to prove the symbol shipped (stale-bundle footgun).
- **Worktree:** `/Users/soonoh/project/soonoh/plan42-worktree130`, branch `feat/creative-table-input`. node_modules present (`@lexical/table` 0.38.2 installed).

---

## File Structure

| File | Responsibility |
| --- | --- |
| `engines/collavre/app/javascript/lib/lexical/table_transformer.js` (Create) | The `TABLE` markdown ElementTransformer (import+export) + helpers, ported from the playground. Kept in its own module so `markdown_serialize.js` stays focused and the transformer is unit-testable in isolation. |
| `engines/collavre/app/javascript/lib/lexical/markdown_serialize.js` (Modify) | Add `TABLE` transformer to `MARKDOWN_TRANSFORMERS`. |
| `engines/collavre/app/javascript/components/plugins/table_hover_actions_plugin.jsx` (Create) | `.jsx` port of the playground `TableHoverActionsPlugin` — cell-boundary "+" buttons. |
| `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx` (Modify) | Register table nodes, add table theme keys, mount `TablePlugin` + `TableHoverActionsPlugin`, add toolbar insert button. |
| `engines/collavre/app/javascript/lib/lexical/__tests__/table_transformer.test.js` (Create) | Round-trip unit tests for the markdown transformer. |
| `engines/collavre/app/assets/stylesheets/...` table CSS (Create/Modify — confirm exact stylesheet at impl time) | `.lexical-table*` rules incl. hover-action buttons. |
| `package.json` (Modify) | Declare `@lexical/table` (already in node_modules, missing from deps). |
| `engines/collavre/config/locales/*.yml` (Modify) | en/ko strings for the toolbar button. |

---

## Task 1: Declare the dependency and register table nodes

**Files:**
- Modify: `package.json` (dependencies block)
- Modify: `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx:1001-1013` (nodes array) and theme object (line 65-118)

**Interfaces:**
- Produces: `TableNode`, `TableRowNode`, `TableCellNode` registered in `initialConfig.nodes`; theme keys `table`, `tableRow`, `tableCell`, `tableCellHeader`, `tableSelection`, `tableSelected`, `tableAddRows`, `tableAddColumns`, `tableCellActionButtonContainer`, `tableCellActionButton`, `tableScrollableWrapper` available to later tasks.

- [ ] **Step 1: Add the dependency to package.json**

In `package.json`, add to `dependencies` (keep alphabetical with the other `@lexical/*` entries), matching the installed version:

```json
    "@lexical/table": "^0.38.2",
```

- [ ] **Step 2: Import the table nodes in InlineLexicalEditor.jsx**

Add near the other `@lexical/*` imports (after the `@lexical/list` import at line 22):

```jsx
import { TableNode, TableRowNode, TableCellNode } from "@lexical/table"
```

- [ ] **Step 3: Add table theme keys**

In the `theme` object (InlineLexicalEditor.jsx:65), add these keys (class names are ours; CSS comes in Task 5):

```jsx
  table: "lexical-table",
  tableScrollableWrapper: "lexical-table-wrapper",
  tableRow: "lexical-table-row",
  tableCell: "lexical-table-cell",
  tableCellHeader: "lexical-table-cell-header",
  tableSelected: "lexical-table-selected",
  tableSelection: "lexical-table-selection",
  tableAddRows: "lexical-table-add-rows",
  tableAddColumns: "lexical-table-add-columns",
  tableCellActionButtonContainer: "lexical-table-cell-action-container",
  tableCellActionButton: "lexical-table-cell-action-button",
```

- [ ] **Step 4: Register the nodes**

In `initialConfig.nodes` (InlineLexicalEditor.jsx:1001), add the three node classes after `VideoNode`:

```jsx
        VideoNode,
        TableNode,
        TableRowNode,
        TableCellNode
```

- [ ] **Step 5: Verify the build compiles**

Run: `cd /Users/soonoh/project/soonoh/plan42-worktree130 && npm run build`
Expected: build succeeds, no "Could not resolve @lexical/table" error.

- [ ] **Step 6: Commit**

```bash
git add package.json engines/collavre/app/javascript/components/InlineLexicalEditor.jsx
git commit -m "feat(creatives): register Lexical table nodes and theme keys"
```

---

## Task 2: The TABLE markdown transformer (the linchpin)

**Files:**
- Create: `engines/collavre/app/javascript/lib/lexical/table_transformer.js`
- Test: `engines/collavre/app/javascript/lib/lexical/__tests__/table_transformer.test.js`

**Interfaces:**
- Consumes: `@lexical/table` (`$isTableNode`, `$isTableRowNode`, `$isTableCellNode`, `$createTableNode`, `$createTableRowNode`, `$createTableCellNode`, `TableCellHeaderStates`), `@lexical/markdown` (`$convertToMarkdownString`, `$convertFromMarkdownString`), `lexical` (`$isParagraphNode`, `$isTextNode`).
- Produces: `export const TABLE` — a Lexical ElementTransformer object consumed by `markdown_serialize.js`. It is self-referential: cell content is (de)serialized with the **same** transformer list, passed in lazily to avoid a circular import.

> **Why a lazy transformer list:** the playground passes `PLAYGROUND_TRANSFORMERS` (which includes `TABLE` itself) into the per-cell `$convertToMarkdownString`/`$convertFromMarkdownString`. To avoid `table_transformer.js` ↔ `markdown_serialize.js` circular import, expose a setter the serializer calls once at module load: `setCellTransformers(list)`. Cells never nest tables, so recursion is bounded regardless.

- [ ] **Step 1: Write the failing round-trip test**

Create `engines/collavre/app/javascript/lib/lexical/__tests__/table_transformer.test.js`. This uses a headless Lexical editor (mirror the harness already used in `markdown_serialize.test.js` — read that file first for the exact `createEditor`/node-registration setup and copy its pattern):

```js
import { createEditor } from "lexical"
import { $convertFromMarkdownString, $convertToMarkdownString } from "@lexical/markdown"
import { TableNode, TableRowNode, TableCellNode } from "@lexical/table"
import { HeadingNode, QuoteNode } from "@lexical/rich-text"
import { ListItemNode, ListNode } from "@lexical/list"
import { LinkNode } from "@lexical/link"
import { CodeNode } from "@lexical/code"
import { MARKDOWN_TRANSFORMERS } from "../markdown_serialize"

function withEditor(fn) {
  const editor = createEditor({
    nodes: [HeadingNode, QuoteNode, CodeNode, ListItemNode, ListNode, LinkNode,
            TableNode, TableRowNode, TableCellNode],
    onError: (e) => { throw e }
  })
  let out
  editor.update(() => { out = fn() }, { discrete: true })
  return { editor, out }
}

function roundTrip(markdown) {
  const editor = createEditor({
    nodes: [HeadingNode, QuoteNode, CodeNode, ListItemNode, ListNode, LinkNode,
            TableNode, TableRowNode, TableCellNode],
    onError: (e) => { throw e }
  })
  let result = ""
  editor.update(() => {
    $convertFromMarkdownString(markdown, MARKDOWN_TRANSFORMERS)
  }, { discrete: true })
  editor.getEditorState().read(() => {
    result = $convertToMarkdownString(MARKDOWN_TRANSFORMERS)
  })
  return result
}

describe("TABLE markdown transformer", () => {
  test("round-trips a header + body table", () => {
    const md = "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Linus | 54 |"
    expect(roundTrip(md)).toContain("| Name | Age |")
    expect(roundTrip(md)).toContain("| --- | --- |")
    expect(roundTrip(md)).toContain("| Ada | 36 |")
    expect(roundTrip(md)).toContain("| Linus | 54 |")
  })

  test("round-trips a table with empty cells", () => {
    const md = "| A | B |\n| --- | --- |\n|  | y |"
    const out = roundTrip(md)
    expect(out).toContain("| A | B |")
    expect(out).toContain("|  | y |")
  })

  test("preserves inline formatting inside cells", () => {
    const md = "| H |\n| --- |\n| **bold** |"
    expect(roundTrip(md)).toContain("**bold**")
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/soonoh/project/soonoh/plan42-worktree130 && npx jest table_transformer --runInBand`
Expected: FAIL — `MARKDOWN_TRANSFORMERS` has no TABLE transformer yet, so `| Name | Age |` survives as a literal paragraph, not a reconstructed table (and the divider `| --- |` round-trips wrong / header state is lost).

- [ ] **Step 3: Write the transformer**

Create `engines/collavre/app/javascript/lib/lexical/table_transformer.js`, ported from `lexical-playground/src/plugins/MarkdownTransformers/index.ts` (the `TABLE` ElementTransformer + `mapToTableCells` + `$createTableCell` + `getTableColumnsSize`), adapted to `.js` and a lazy transformer list:

```js
import {
  $createTableCellNode,
  $createTableNode,
  $createTableRowNode,
  $isTableCellNode,
  $isTableNode,
  $isTableRowNode,
  TableCellHeaderStates
} from "@lexical/table"
import { $convertFromMarkdownString, $convertToMarkdownString } from "@lexical/markdown"
import { $isParagraphNode, $isTextNode } from "lexical"

const TABLE_ROW_REG_EXP = /^(?:\|)(.+)(?:\|)\s?$/
const TABLE_ROW_DIVIDER_REG_EXP = /^(\| ?:?-*:? ?)+\|\s?$/

// Cell content is (de)serialized with the full transformer list (including this
// TABLE transformer). markdown_serialize.js injects it once at load to avoid a
// circular import. Cells never nest tables, so recursion stays bounded.
let cellTransformers = []
export function setCellTransformers(list) {
  cellTransformers = list
}

function getTableColumnsSize(table) {
  const row = table.getFirstChild()
  return $isTableRowNode(row) ? row.getChildrenSize() : 0
}

function $createTableCell(textContent) {
  const text = textContent.replace(/\\n/g, "\n")
  const cell = $createTableCellNode(TableCellHeaderStates.NO_STATUS)
  $convertFromMarkdownString(text, cellTransformers, cell)
  return cell
}

function mapToTableCells(textContent) {
  const match = textContent.match(TABLE_ROW_REG_EXP)
  if (!match || !match[1]) return null
  return match[1].split("|").map((text) => $createTableCell(text))
}

export const TABLE = {
  dependencies: [],
  export: (node) => {
    if (!$isTableNode(node)) return null
    const output = []
    for (const row of node.getChildren()) {
      if (!$isTableRowNode(row)) continue
      const rowOutput = []
      let isHeaderRow = false
      for (const cell of row.getChildren()) {
        if ($isTableCellNode(cell)) {
          rowOutput.push(
            $convertToMarkdownString(cellTransformers, cell).replace(/\n/g, "\\n").trim()
          )
          if (cell.__headerState === TableCellHeaderStates.ROW) {
            isHeaderRow = true
          }
        }
      }
      output.push(`| ${rowOutput.join(" | ")} |`)
      if (isHeaderRow) {
        output.push(`| ${rowOutput.map(() => "---").join(" | ")} |`)
      }
    }
    return output.join("\n")
  },
  regExp: TABLE_ROW_REG_EXP,
  replace: (parentNode, _children, match) => {
    if (TABLE_ROW_DIVIDER_REG_EXP.test(match[0])) {
      const table = parentNode.getPreviousSibling()
      if (!table || !$isTableNode(table)) return
      const rows = table.getChildren()
      const lastRow = rows[rows.length - 1]
      if (!lastRow || !$isTableRowNode(lastRow)) return
      lastRow.getChildren().forEach((cell) => {
        if (!$isTableCellNode(cell)) return
        cell.setHeaderStyles(TableCellHeaderStates.ROW, TableCellHeaderStates.ROW)
      })
      parentNode.remove()
      return
    }

    const matchCells = mapToTableCells(match[0])
    if (matchCells == null) return

    const rows = [matchCells]
    let sibling = parentNode.getPreviousSibling()
    let maxCells = matchCells.length
    while (sibling) {
      if (!$isParagraphNode(sibling) || sibling.getChildrenSize() !== 1) break
      const firstChild = sibling.getFirstChild()
      if (!$isTextNode(firstChild)) break
      const cells = mapToTableCells(firstChild.getTextContent())
      if (cells == null) break
      maxCells = Math.max(maxCells, cells.length)
      rows.unshift(cells)
      const previousSibling = sibling.getPreviousSibling()
      sibling.remove()
      sibling = previousSibling
    }

    const table = $createTableNode()
    for (const cells of rows) {
      const tableRow = $createTableRowNode()
      table.append(tableRow)
      for (let i = 0; i < maxCells; i++) {
        tableRow.append(i < cells.length ? cells[i] : $createTableCell(""))
      }
    }

    const previousSibling = parentNode.getPreviousSibling()
    if ($isTableNode(previousSibling) && getTableColumnsSize(previousSibling) === maxCells) {
      previousSibling.append(...table.getChildren())
      parentNode.remove()
    } else {
      parentNode.replace(table)
    }
    table.selectEnd()
  },
  type: "element"
}
```

> **Note on `setHeaderStyles`:** confirm the method exists on `TableCellNode` in 0.38.2 (the playground used it). If the API renamed it, use `cell.setHeaderStyles(...)` equivalent or `$createTableCellNode(TableCellHeaderStates.ROW)`. Verify at impl time via `grep -n "setHeaderStyles\|setHeaderState" node_modules/@lexical/table/LexicalTable.dev.mjs`.

- [ ] **Step 4: Wire it into markdown_serialize.js**

Modify `engines/collavre/app/javascript/lib/lexical/markdown_serialize.js`. Add the import and the `setCellTransformers` call, and include `TABLE` in `MARKDOWN_TRANSFORMERS`:

```js
import { TABLE, setCellTransformers } from "./table_transformer"
```

Change the `MARKDOWN_TRANSFORMERS` definition (currently line 170) to include `TABLE` first among our custom transformers, then register the cell transformer list:

```js
export const MARKDOWN_TRANSFORMERS = [
  TABLE,
  DECORATOR_ELEMENT_TRANSFORMER,
  DECORATOR_TEXT_TRANSFORMER,
  COLOR_TRANSFORMER,
  ...TRANSFORMERS
]

// Tables serialize their cell content with the same transformer set.
setCellTransformers(MARKDOWN_TRANSFORMERS)
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd /Users/soonoh/project/soonoh/plan42-worktree130 && npx jest table_transformer --runInBand`
Expected: PASS (3 tests).

- [ ] **Step 6: Run the existing markdown_serialize suite for regressions**

Run: `npx jest markdown_serialize --runInBand`
Expected: PASS — color/decorator transformers still work (TABLE only claims `|`-delimited rows).

- [ ] **Step 7: Commit**

```bash
git add engines/collavre/app/javascript/lib/lexical/table_transformer.js \
        engines/collavre/app/javascript/lib/lexical/__tests__/table_transformer.test.js \
        engines/collavre/app/javascript/lib/lexical/markdown_serialize.js
git commit -m "feat(creatives): round-trip Lexical tables through canonical Markdown"
```

---

## Task 3: Mount TablePlugin and the toolbar insert button

**Files:**
- Modify: `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx`
- Modify: `engines/collavre/config/locales/en.yml`, `engines/collavre/config/locales/ko.yml` (confirm exact locale file the editor reads at impl time; the editor currently has no i18n wiring for toolbar tooltips — they are literal `title="..."` strings. Match the existing pattern: if the toolbar uses literal English titles today, add the table button title as a literal English string AND a ko translation is satisfied by the localized data attribute approach used elsewhere. If no i18n channel exists in this component, expose the label via the container `data-*` like `placeholderText` is. Pick whichever matches the established pattern after reading the component + its Stimulus host.)

**Interfaces:**
- Consumes: `INSERT_TABLE_COMMAND` from `@lexical/table`; `TablePlugin` from `@lexical/react/LexicalTablePlugin`.
- Produces: a working insert-table toolbar button; cell navigation/selection behavior from `TablePlugin`.

- [ ] **Step 1: Import TablePlugin and the insert command**

Add to InlineLexicalEditor.jsx imports:

```jsx
import { TablePlugin } from "@lexical/react/LexicalTablePlugin"
import { INSERT_TABLE_COMMAND } from "@lexical/table"
```

- [ ] **Step 2: Mount TablePlugin in EditorInner**

In `EditorInner`'s plugin list (after `<ListPlugin />`, line 905):

```jsx
        <TablePlugin hasCellMerge={false} hasCellBackgroundColor={false} />
```

(Merge and background-color are intentionally disabled — GFM can't represent them.)

- [ ] **Step 3: Add the toolbar insert-table button**

In `Toolbar()`, add a callback near `toggleList`:

```jsx
  const insertTable = useCallback(() => {
    editor.dispatchCommand(INSERT_TABLE_COMMAND, {
      columns: "3",
      rows: "3",
      includeHeaders: true
    })
  }, [editor])
```

Add the button after the numbered-list button (line 716), before the separator:

```jsx
      <button
        type="button"
        className="lexical-toolbar-btn"
        onClick={insertTable}
        title="Insert table"
        aria-label="Insert table">
        ▦
      </button>
```

- [ ] **Step 4: Build and verify the symbol shipped**

Run: `npm run build && grep -ac "INSERT_TABLE_COMMAND" app/assets/builds/*.js`
Expected: build succeeds; grep count ≥ 1 (proves the handler is in the production bundle, not just source — stale-bundle footgun).

- [ ] **Step 5: Commit**

```bash
git add engines/collavre/app/javascript/components/InlineLexicalEditor.jsx engines/collavre/config/locales/*.yml
git commit -m "feat(creatives): add insert-table toolbar button and cell editing plugin"
```

---

## Task 4: Cell-boundary add-row/add-column buttons

**Files:**
- Create: `engines/collavre/app/javascript/components/plugins/table_hover_actions_plugin.jsx`
- Modify: `engines/collavre/app/javascript/components/InlineLexicalEditor.jsx` (mount the plugin)

**Interfaces:**
- Consumes: `@lexical/table` (`$insertTableRowAtSelection`, `$insertTableColumnAtSelection`, `getTableElement` / `$getTableAndElementByKey` — confirm the exact accessor in 0.38.2), `@lexical/react/LexicalComposerContext`, `lexical` (`$getNearestNodeFromDOMNode`).
- Produces: hovering near a table's bottom edge shows a full-width "+" button that appends a row; hovering near the right edge shows a full-height "+" button that appends a column.

- [ ] **Step 1: Port the plugin to .jsx**

Create `table_hover_actions_plugin.jsx`, ported from `lexical-playground/src/plugins/TableHoverActionsPlugin/index.tsx`. Strip TypeScript types; keep the mouse-move/debounce/ResizeObserver logic. The two action calls are:

```jsx
import { useEffect, useRef, useState, useCallback } from "react"
import { createPortal } from "react-dom"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  $getTableAndElementByKey,
  $insertTableColumnAtSelection,
  $insertTableRowAtSelection,
  $isTableCellNode,
  $isTableNode,
  TableNode,
  getTableElement
} from "@lexical/table"
import { $getNearestNodeFromDOMNode } from "lexical"

const BUTTON_WIDTH_PX = 20

export default function TableHoverActionsPlugin({ anchorElem }) {
  const [editor] = useLexicalComposerContext()
  const [isShownRow, setShownRow] = useState(false)
  const [isShownColumn, setShownColumn] = useState(false)
  const [position, setPosition] = useState({})
  const tableDOMNodeRef = useRef(null)
  // ... port getMouseInfo, debounced mousemove, ResizeObserver, and the
  // portal-rendered <button className=theme.tableAddRows/Columns> from the
  // playground. On row-button click: editor.update(() => { selectEnd table;
  // $insertTableRowAtSelection(); setShownRow(false) }). On column-button click:
  // $insertTableColumnAtSelection().
}
```

> **Impl guidance:** read the full playground source verbatim (it is ~280 lines) and translate 1:1. Confirm `getTableElement` and `$getTableAndElementByKey` exist in 0.38.2 with `grep -n "getTableElement\|getTableAndElementByKey\|getDOMCellFromTarget" node_modules/@lexical/table/LexicalTable.dev.mjs`; if an accessor differs, use the nearest equivalent (e.g. derive the table DOM via `editor.getElementByKey(tableNode.getKey())`). Keep the class names from the theme (`tableAddRows`, `tableAddColumns`).

- [ ] **Step 2: Mount the plugin**

In `EditorInner`, after `<TablePlugin .../>`, mount it against the editor inner container. The simplest anchor is the editor shell ref — pass `anchorElem` as the `.lexical-editor-inner` element. If wiring a ref is heavy, default `anchorElem` to `document.body` inside the plugin (the playground default) and position via absolute coordinates:

```jsx
        <TableHoverActionsPlugin />
```

- [ ] **Step 3: Build**

Run: `npm run build && grep -ac "insertTableRowAtSelection" app/assets/builds/*.js`
Expected: build succeeds; grep ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add engines/collavre/app/javascript/components/plugins/table_hover_actions_plugin.jsx \
        engines/collavre/app/javascript/components/InlineLexicalEditor.jsx
git commit -m "feat(creatives): add cell-boundary add-row/add-column buttons"
```

---

## Task 5: Table CSS

**Files:**
- Create/Modify: the stylesheet that defines `.lexical-toolbar` / `.lexical-content-editable` (find it: `grep -rln "lexical-content-editable" engines/collavre/app/assets/stylesheets`). Add a co-located `.lexical-table*` block.

**Interfaces:**
- Consumes: theme class names from Task 1.
- Produces: visible bordered table; header row shading; hover "+" buttons.

- [ ] **Step 1: Add table styles**

Port the playground's table CSS (from `PlaygroundEditorTheme.css`), renaming selectors to the `lexical-table*` classes and using design tokens (`var(--border-color)`, `var(--surface-hover)`, etc. — match tokens already used in this stylesheet; do NOT introduce undefined tokens like `--text-link`). Minimum rules:

```css
.lexical-table {
  border-collapse: collapse;
  table-layout: fixed;
  width: fit-content;
  margin: 12px 0;
}
.lexical-table-cell {
  border: 1px solid var(--border-color);
  padding: 6px 8px;
  vertical-align: top;
  position: relative;
  min-width: 75px;
}
.lexical-table-cell-header {
  background-color: var(--surface-hover);
  font-weight: 600;
}
.lexical-table-selected { outline: 2px solid var(--color-brand); }
.lexical-table-add-rows,
.lexical-table-add-columns {
  position: absolute;
  background-color: var(--surface-hover);
  border: 0;
  cursor: pointer;
}
.lexical-table-add-rows:hover,
.lexical-table-add-columns:hover { background-color: var(--surface-active, var(--color-highlight)); }
```

Add a `+` glyph via `::after { content: "+"; ... }` (no external SVG dependency — the playground used `plus.svg`; a CSS glyph avoids an asset import).

- [ ] **Step 2: Build and commit**

```bash
npm run build
git add engines/collavre/app/assets/stylesheets
git commit -m "style(creatives): table and cell-boundary button styling"
```

---

## Task 6: Verification — full round-trip in preview

**Files:** none (manual + automated verification)

- [ ] **Step 1: Jest full editor suite**

Run: `npx jest lexical --runInBand`
Expected: all green (table_transformer + markdown_serialize + existing lexical tests).

- [ ] **Step 2: Start the preview server**

Per project convention (memory): `PORT=4130 bin/rails server -b 0.0.0.0` from the worktree (NOT `bin/dev` — github_mock port collision). Register the preview via `preview_attach` so the user gets a link. URL: `http://macbook-pro.tailadceed.ts.net:4130`.

- [ ] **Step 3: Headless round-trip check (gstack /browse)**

Insert a table via the toolbar, type into cells, add a row and a column via the boundary buttons, save, reopen the creative. Verify the table reappears with the same cells. Then check the stored `markdown_source` (via the creative API / DB) is a GFM pipe table. Watch for the stale-bundle footgun: if the toolbar button is missing, `grep -ac` the served bundle for `INSERT_TABLE_COMMAND`.

- [ ] **Step 4: rubocop / Ruby tests (pre-push)**

Run (mise-activated shell — memory): `bundle exec rubocop` and the JS lint/test gate. Note: `scan_ruby`/`test_js` are pre-existingly red on main (memory) — only a NEW failure is a regression.

- [ ] **Step 5: Stop preview, push, open PR**

Stop the preview server (kill PID, `preview_detach`). Push with `gh auth token` HTTPS if SSH is the wrong identity (memory). Open the PR (English title/body, conventional commit). Register with `pr_monitor`. Move creative 14143 under "리뷰" (id 10535) per the trigger instruction.

---

## Self-Review

**Spec coverage:**
- "테이블 툴바 아이콘" → Task 3 (toolbar insert button) ✓
- "좌우로 컬럼 및 row 추가하는 셀 경계 버튼" → Task 4 (TableHoverActionsPlugin: add row + add column) ✓
- "lexical-playground 참고" → Tasks 2 & 4 port playground source ✓
- Markdown-canonical round-trip (implicit hard requirement) → Task 2 + Task 6 verification ✓

**Placeholder scan:** Task 4 Step 1 intentionally leaves the hover-plugin body as "port verbatim from playground" rather than reproducing ~280 lines — flagged with the exact source path and the API-confirmation grep. This is a deliberate port-1:1 instruction, not a vague placeholder. All other code steps are complete.

**Type consistency:** `MARKDOWN_TRANSFORMERS` array name consistent across Tasks 2/3; theme keys defined in Task 1 are consumed by Tasks 4/5; `setCellTransformers`/`cellTransformers` consistent within Task 2.

**Open verification items to resolve during impl (not blockers):**
- `TableCellNode#setHeaderStyles` exists in 0.38.2 (Task 2 Step 3 note)
- `getTableElement` / `$getTableAndElementByKey` accessor names in 0.38.2 (Task 4 Step 1 note)
- exact i18n channel for the toolbar tooltip (Task 3 Files note)
- exact stylesheet file for table CSS (Task 5 Files note)
