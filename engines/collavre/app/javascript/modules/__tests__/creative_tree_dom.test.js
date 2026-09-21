/**
 * Characterization tests for the tree-DOM navigation/geometry cluster extracted
 * from creative_row_editor.js (slice 2 of the god-file decomposition).
 *
 * These pin the CURRENT behavior of the sibling/level/parent computations that
 * feed the structural-move paths (levelUp/levelDown/addNew/move) — the inputs to
 * the recurring "parentId loss / wrong ordering" bug class. They are written
 * against a jsdom fixture that mirrors the real creative-tree render: a
 * `creative-tree-row` custom element wrapping a `.creative-tree` node, with
 * `.creative-children` containers as siblings of the row.
 *
 * Intentionally behavior-preserving: any surprising result below (e.g. the
 * before/after id inversion in siblingOrderingForRow) documents existing
 * behavior, not an endorsement of it.
 */
import {
  creativeTreeElement,
  creativeIdFrom,
  siblingTreeRow,
  siblingOrderingForRow,
  treeContainerElement,
  nodeAfterTreeBlock,
  normalizeRowNode,
  childrenContainerForTree,
  ensureChildrenContainer,
  expandChildrenContainer,
  moveTreeBlock,
  listAllTreeNodes,
  findPreviousTree,
  getTreeLevel,
  updateTreeLevels,
  setTreeLevel,
  removeTreeElement,
} from '../creative_tree_dom';

// Build one row: <creative-tree-row><div.creative-tree/></creative-tree-row>
function makeRow(id, { parentId = '', level = 1 } = {}) {
  const row = document.createElement('creative-tree-row');
  row.setAttribute('creative-id', String(id));
  row.setAttribute('level', String(level));
  const tree = document.createElement('div');
  tree.className = 'creative-tree';
  tree.id = `creative-${id}`;
  tree.dataset.id = String(id);
  tree.dataset.parentId = parentId;
  tree.dataset.level = String(level);
  row.appendChild(tree);
  return { row, tree };
}

function makeChildrenContainer(parentId) {
  const c = document.createElement('div');
  c.className = 'creative-children';
  c.id = `creative-children-${parentId}`;
  return c;
}

function treeOf(row) {
  return row.querySelector('.creative-tree');
}

let root;
beforeEach(() => {
  document.body.innerHTML = '';
  root = document.createElement('div');
  root.id = 'creatives';
  document.body.appendChild(root);
});

describe('creativeTreeElement / creativeIdFrom', () => {
  test('creativeTreeElement returns the node itself when it is a .creative-tree', () => {
    const { tree } = makeRow(1);
    expect(creativeTreeElement(tree)).toBe(tree);
  });

  test('creativeTreeElement descends into a wrapping row', () => {
    const { row, tree } = makeRow(1);
    expect(creativeTreeElement(row)).toBe(tree);
  });

  test('creativeTreeElement returns null for a nullish node', () => {
    expect(creativeTreeElement(null)).toBeNull();
  });

  test('creativeIdFrom reads the inner .creative-tree data-id from a row', () => {
    const { row } = makeRow(42);
    expect(creativeIdFrom(row)).toBe('42');
  });

  test('creativeIdFrom falls back to creative-id / data-id attributes', () => {
    const el = document.createElement('div');
    el.setAttribute('creative-id', '7');
    expect(creativeIdFrom(el)).toBe('7');
  });

  test('creativeIdFrom returns empty string when nothing identifies the node', () => {
    expect(creativeIdFrom(null)).toBe('');
  });
});

describe('siblingTreeRow', () => {
  test('finds the next/previous row, skipping text nodes', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    root.appendChild(a.row);
    root.appendChild(document.createTextNode('\n  '));
    root.appendChild(b.row);

    expect(siblingTreeRow(a.row, 'next')).toBe(b.row);
    expect(siblingTreeRow(b.row, 'previous')).toBe(a.row);
  });

  test('skips over intervening .creative-children containers', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    root.appendChild(a.row);
    root.appendChild(makeChildrenContainer(1)); // between the two rows
    root.appendChild(b.row);

    expect(siblingTreeRow(a.row, 'next')).toBe(b.row);
    expect(siblingTreeRow(b.row, 'previous')).toBe(a.row);
  });

  test('returns null at the ends', () => {
    const a = makeRow(1);
    root.appendChild(a.row);
    expect(siblingTreeRow(a.row, 'next')).toBeNull();
    expect(siblingTreeRow(a.row, 'previous')).toBeNull();
    expect(siblingTreeRow(null, 'next')).toBeNull();
  });
});

describe('siblingOrderingForRow', () => {
  // Pins the (surprising) mapping: beforeId := NEXT sibling, afterId := PREVIOUS
  // sibling. This is existing behavior consumed by persistStructureChange.
  test('beforeId comes from the next sibling, afterId from the previous', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    const c = makeRow(3);
    root.appendChild(a.row);
    root.appendChild(b.row);
    root.appendChild(c.row);

    expect(siblingOrderingForRow(b.row)).toEqual({ beforeId: '3', afterId: '1' });
  });

  test('empty ids at the boundaries', () => {
    const a = makeRow(1);
    root.appendChild(a.row);
    expect(siblingOrderingForRow(a.row)).toEqual({ beforeId: '', afterId: '' });
  });
});

describe('treeContainerElement', () => {
  test('returns the row parent when the tree has a wrapping row', () => {
    const { row, tree } = makeRow(1);
    root.appendChild(row);
    expect(treeContainerElement(tree)).toBe(root);
  });

  test('returns null for nullish tree', () => {
    expect(treeContainerElement(null)).toBeNull();
  });
});

describe('nodeAfterTreeBlock', () => {
  test('returns the next row when there is no children container', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    root.appendChild(a.row);
    root.appendChild(b.row);
    expect(nodeAfterTreeBlock(a.tree)).toBe(b.row);
  });

  test('skips the tree\'s own children container to the node after it', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    const children = makeChildrenContainer(1);
    root.appendChild(a.row);
    root.appendChild(children);
    root.appendChild(b.row);
    expect(nodeAfterTreeBlock(a.tree)).toBe(b.row);
  });
});

describe('normalizeRowNode', () => {
  test('returns the row unchanged', () => {
    const { row } = makeRow(1);
    expect(normalizeRowNode(row)).toBe(row);
  });

  test('maps a .creative-tree node to its wrapping row', () => {
    const { row, tree } = makeRow(1);
    expect(normalizeRowNode(tree)).toBe(row);
  });

  test('returns nullish input as null', () => {
    expect(normalizeRowNode(null)).toBeNull();
  });
});

describe('childrenContainerForTree', () => {
  test('finds the container by id', () => {
    const { row, tree } = makeRow(1);
    const children = makeChildrenContainer(1);
    root.appendChild(row);
    root.appendChild(children);
    expect(childrenContainerForTree(tree)).toBe(children);
  });

  test('finds the container as a following sibling of the row', () => {
    const { row, tree } = makeRow(5);
    const children = document.createElement('div');
    children.className = 'creative-children'; // no matching id
    root.appendChild(row);
    root.appendChild(children);
    expect(childrenContainerForTree(tree)).toBe(children);
  });

  test('returns null when no container exists', () => {
    const { row, tree } = makeRow(9);
    root.appendChild(row);
    expect(childrenContainerForTree(tree)).toBeNull();
  });
});

describe('ensureChildrenContainer', () => {
  test('reuses an existing container', () => {
    const { row, tree } = makeRow(1);
    const existing = makeChildrenContainer(1);
    root.appendChild(row);
    root.appendChild(existing);
    expect(ensureChildrenContainer(tree)).toBe(existing);
  });

  test('creates a container with child level (+1) load url and inserts after the row', () => {
    const { row, tree } = makeRow(3, { level: 2 });
    root.appendChild(row);

    const created = ensureChildrenContainer(tree);

    expect(created).not.toBeNull();
    expect(created.id).toBe('creative-children-3');
    expect(created.classList.contains('creative-children')).toBe(true);
    expect(created.dataset.expanded).toBe('true');
    // level+1 = 3, select_mode 0
    expect(created.dataset.loadUrl).toBe('/creatives/3/children?level=3&select_mode=0');
    // inserted into the row's parent, right after the row
    expect(created.previousElementSibling).toBe(row);
  });

  test('returns null when the tree has no id', () => {
    const tree = document.createElement('div');
    tree.className = 'creative-tree';
    root.appendChild(tree);
    expect(ensureChildrenContainer(tree)).toBeNull();
  });
});

describe('expandChildrenContainer', () => {
  test('clears display and marks expanded', () => {
    const c = makeChildrenContainer(1);
    c.style.display = 'none';
    expandChildrenContainer(c);
    expect(c.style.display).toBe('');
    expect(c.dataset.expanded).toBe('true');
  });

  test('no-ops on nullish container', () => {
    expect(() => expandChildrenContainer(null)).not.toThrow();
  });
});

describe('moveTreeBlock', () => {
  test('moves the row and its children container into the target (append)', () => {
    const src = makeRow(1);
    const children = makeChildrenContainer(1);
    const targetParent = makeChildrenContainer(99);
    root.appendChild(src.row);
    root.appendChild(children);
    root.appendChild(targetParent);

    moveTreeBlock(src.tree, targetParent);

    expect(src.row.parentNode).toBe(targetParent);
    expect(children.parentNode).toBe(targetParent);
    // row moved before its children container (append order preserved)
    expect([...targetParent.children]).toEqual([src.row, children]);
  });

  test('inserts before a reference node', () => {
    const src = makeRow(1);
    const ref = makeRow(2);
    const targetParent = makeChildrenContainer(99);
    // Keep src.row's next sibling from being a .creative-children, otherwise
    // childrenContainerForTree's sibling fallback would treat targetParent as
    // src's own children container (covered separately above).
    const srcHolder = document.createElement('div');
    srcHolder.appendChild(src.row);
    root.appendChild(srcHolder);
    targetParent.appendChild(ref.row);
    root.appendChild(targetParent);

    moveTreeBlock(src.tree, targetParent, ref.row);

    expect([...targetParent.children]).toEqual([src.row, ref.row]);
  });

  test('no-ops without a target', () => {
    const src = makeRow(1);
    root.appendChild(src.row);
    expect(() => moveTreeBlock(src.tree, null)).not.toThrow();
  });
});

describe('listAllTreeNodes', () => {
  test('returns all .creative-tree under #creatives in document order', () => {
    const a = makeRow(1);
    const b = makeRow(2);
    root.appendChild(a.row);
    root.appendChild(b.row);
    expect(listAllTreeNodes()).toEqual([a.tree, b.tree]);
  });
});

describe('getTreeLevel', () => {
  test('reads data-level when present and positive', () => {
    const { tree } = makeRow(1, { level: 4 });
    expect(getTreeLevel(tree)).toBe(4);
  });

  test('falls back to the wrapping row level attribute when data-level absent', () => {
    const { row, tree } = makeRow(1, { level: 3 });
    delete tree.dataset.level;
    root.appendChild(row);
    expect(getTreeLevel(tree)).toBe(3);
  });

  test('defaults to 1 for nullish tree', () => {
    expect(getTreeLevel(null)).toBe(1);
  });
});

describe('findPreviousTree', () => {
  // #creatives: row1(L1), [children-1: row11(L2)], row2(L1)
  function buildNested() {
    const one = makeRow(1, { level: 1 });
    const children1 = makeChildrenContainer(1);
    const eleven = makeRow(11, { parentId: '1', level: 2 });
    children1.appendChild(eleven.row);
    const two = makeRow(2, { level: 1 });
    root.appendChild(one.row);
    root.appendChild(children1);
    root.appendChild(two.row);
    return { one, eleven, two };
  }

  test('returns the nearest previous tree at the same level', () => {
    const { one, two } = buildNested();
    expect(findPreviousTree(two.tree)).toBe(one.tree);
  });

  test('returns null when the previous tree is at a shallower level', () => {
    const { eleven } = buildNested();
    // eleven (L2) is preceded only by one (L1) which is shallower -> null
    expect(findPreviousTree(eleven.tree)).toBeNull();
  });

  test('returns null for the first tree', () => {
    const { one } = buildNested();
    expect(findPreviousTree(one.tree)).toBeNull();
  });
});

describe('updateTreeLevels / setTreeLevel', () => {
  test('updateTreeLevels applies delta to the tree and its child rows recursively', () => {
    const parent = makeRow(1, { level: 1 });
    const children = makeChildrenContainer(1);
    const child = makeRow(11, { parentId: '1', level: 2 });
    children.appendChild(child.row);
    root.appendChild(parent.row);
    root.appendChild(children);

    updateTreeLevels(parent.tree, 1);

    expect(parent.tree.dataset.level).toBe('2');
    expect(parent.row.getAttribute('level')).toBe('2');
    expect(child.tree.dataset.level).toBe('3');
    expect(child.row.getAttribute('level')).toBe('3');
  });

  test('updateTreeLevels floors the level at 1', () => {
    const { tree, row } = makeRow(1, { level: 1 });
    root.appendChild(row);
    updateTreeLevels(tree, -5);
    expect(tree.dataset.level).toBe('1');
  });

  test('setTreeLevel computes the delta to reach the target level', () => {
    const { tree, row } = makeRow(1, { level: 2 });
    root.appendChild(row);
    setTreeLevel(tree, 4);
    expect(tree.dataset.level).toBe('4');
  });

  test('setTreeLevel is a no-op when already at the target', () => {
    const { tree, row } = makeRow(1, { level: 2 });
    root.appendChild(row);
    setTreeLevel(tree, 2);
    expect(tree.dataset.level).toBe('2');
  });
});

describe('removeTreeElement', () => {
  test('removes the wrapping row', () => {
    const { row, tree } = makeRow(1);
    root.appendChild(row);
    removeTreeElement(tree);
    expect(root.querySelector('creative-tree-row')).toBeNull();
  });

  test('no-ops on nullish tree', () => {
    expect(() => removeTreeElement(null)).not.toThrow();
  });

  function addHiddenEmptyState() {
    root.insertAdjacentHTML(
      'beforeend',
      '<div data-creatives-empty-state="" hidden><p>No sub-creatives found.</p></div>'
    );
    return root.querySelector('[data-creatives-empty-state]');
  }

  test('restores the empty-state placeholder once the last row is gone', () => {
    const placeholder = addHiddenEmptyState();
    const { row, tree } = makeRow(1);
    root.appendChild(row);

    removeTreeElement(tree);

    expect(placeholder.hidden).toBe(false);
  });

  test('leaves the placeholder hidden while other rows remain', () => {
    const placeholder = addHiddenEmptyState();
    const { row: first, tree } = makeRow(1);
    const { row: second } = makeRow(2);
    root.appendChild(first);
    root.appendChild(second);

    removeTreeElement(tree);

    expect(placeholder.hidden).toBe(true);
  });
});
