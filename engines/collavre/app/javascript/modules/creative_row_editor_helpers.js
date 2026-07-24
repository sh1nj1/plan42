// Pure, closure-independent helpers extracted from creative_row_editor.js.
//
// Every function here depends only on its arguments (and the module-local
// layout constants below) — none captures editor closure state. Keeping them in
// a separate module shrinks the main editor module and makes these units
// individually testable. Behavior is identical to the original inline versions.

const BULLET_STARTING_LEVEL = 3;
const HEADING_INDENT_STEP_EM = 0.4;
const BULLET_INDENT_STEP_PX = 30;

export function treeRowElement(node) {
  return node && node.closest ? node.closest('creative-tree-row') : null;
}

export function hasDatasetValue(element, key) {
  if (!element || !element.dataset) return false;
  return Object.prototype.hasOwnProperty.call(element.dataset, key);
}

export function setRowDatasetValue(row, key, value) {
  if (!row || !row.dataset) return;
  if (value === undefined || value === null) {
    delete row.dataset[key];
  } else {
    row.dataset[key] = String(value);
  }
}

export function isMarkdownEmpty(md) {
  return !md || md.trim().length === 0;
}

export function buildChildrenLoadUrl(parentId, childLevel, selectMode) {
  const params = new URLSearchParams();
  params.set('level', String(childLevel));
  params.set('select_mode', selectMode ? '1' : '0');
  return `/creatives/${parentId}/children?${params.toString()}`;
}

export function readRowLevel(row) {
  if (!row) return null;
  if (row.isTitle) return 0;
  if (row.getAttribute) {
    const levelAttr = row.getAttribute('level');
    if (levelAttr) {
      const parsed = Number(levelAttr);
      if (!Number.isNaN(parsed)) return parsed;
    }
  }
  if (typeof row.level === 'number') {
    return row.level;
  }
  if (row.level) {
    const parsed = Number(row.level);
    if (!Number.isNaN(parsed)) return parsed;
  }
  const tree = row.querySelector ? row.querySelector('.creative-tree') : null;
  if (tree && tree.dataset?.level) {
    const parsed = Number(tree.dataset.level);
    if (!Number.isNaN(parsed)) return parsed;
  }
  return 1;
}

export function editorPaddingForLevel(level) {
  if (typeof level !== 'number' || Number.isNaN(level) || level <= 1) {
    return '0px';
  }
  if (level <= BULLET_STARTING_LEVEL) {
    const emValue = (level - 1) * HEADING_INDENT_STEP_EM;
    return emValue ? `${emValue}em` : '0px';
  }
  const pxValue = (level - BULLET_STARTING_LEVEL) * BULLET_INDENT_STEP_PX;
  return `${pxValue}px`;
}
