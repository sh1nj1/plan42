/**
 * Characterization tests for the inline creative payload mapping cluster
 * extracted from creative_row_editor.js (slice 3 of the god-file decomposition).
 *
 * These pin the CURRENT behavior of the inverse pair that drives instant UI:
 *   - inlinePayloadFromTree: reads a payload OUT of a rendered tree row's dataset
 *   - updateRowFromData:     writes a server/API payload INTO a row's dataset
 *
 * The fixture mirrors the real creative-tree render: a `creative-tree-row`
 * custom element wrapping a `.creative-tree` node whose `data-id`/`data-parent-id`
 * carry the tree identity.
 *
 * Intentionally behavior-preserving: any surprising result below (e.g. missing
 * fields defaulting to 0/'' rather than being omitted, or `hasOwnProperty`-gated
 * writes) documents existing behavior, not an endorsement of it.
 */
import { inlinePayloadFromTree, updateRowFromData } from '../creative_inline_payload';

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

describe('inlinePayloadFromTree', () => {
  test('returns null for falsy tree', () => {
    expect(inlinePayloadFromTree(null)).toBeNull();
    expect(inlinePayloadFromTree(undefined)).toBeNull();
  });

  test('returns null when tree has no wrapping creative-tree-row', () => {
    const orphan = document.createElement('div');
    orphan.dataset.id = '5';
    expect(inlinePayloadFromTree(orphan)).toBeNull();
  });

  test('returns null when row exists but tree has no data-id', () => {
    const { tree } = makeRow('9');
    delete tree.dataset.id;
    expect(inlinePayloadFromTree(tree)).toBeNull();
  });

  test('builds a fully-defaulted payload from a minimal row (only id)', () => {
    const { tree } = makeRow('42', { parentId: '' });
    expect(inlinePayloadFromTree(tree)).toEqual({
      id: '42',
      description: '',
      description_raw_html: '',
      origin_id: '',
      parent_id: '',
      progress: 0,
      content_type: null,
      markdown_editor: null,
      markdown_source: null,
    });
  });

  test('reads all fields from a fully-populated row', () => {
    const { row, tree } = makeRow('7', { parentId: '3' });
    row.dataset.descriptionHtml = '<p>hi</p>';
    row.dataset.descriptionRawHtml = '<p>raw</p>';
    row.dataset.progressValue = '55';
    row.dataset.originId = '99';
    row.dataset.contentType = 'markdown';
    row.dataset.markdownEditor = 'rich';
    row.dataset.markdownSource = '# hi';
    expect(inlinePayloadFromTree(tree)).toEqual({
      id: '7',
      description: '<p>hi</p>',
      description_raw_html: '<p>raw</p>',
      origin_id: '99',
      parent_id: '3',
      progress: 55,
      content_type: 'markdown',
      markdown_editor: 'rich',
      markdown_source: '# hi',
    });
  });

  test('description falls back to raw html when descriptionHtml absent', () => {
    const { row, tree } = makeRow('8');
    row.dataset.descriptionRawHtml = '<p>only-raw</p>';
    const payload = inlinePayloadFromTree(tree);
    expect(payload.description).toBe('<p>only-raw</p>');
    expect(payload.description_raw_html).toBe('<p>only-raw</p>');
  });

  test('non-numeric progress coerces to 0 (NaN guard)', () => {
    const { row, tree } = makeRow('11');
    row.dataset.progressValue = 'abc';
    expect(inlinePayloadFromTree(tree).progress).toBe(0);
  });

  test('progress present but empty-string reads as 0', () => {
    const { row, tree } = makeRow('12');
    row.dataset.progressValue = '';
    // Number('' ?? 0) === Number('') === 0
    expect(inlinePayloadFromTree(tree).progress).toBe(0);
  });
});

describe('updateRowFromData', () => {
  test('no-ops on falsy row or data', () => {
    const { row } = makeRow('1');
    expect(() => updateRowFromData(null, { description: 'x' })).not.toThrow();
    expect(() => updateRowFromData(row, null)).not.toThrow();
    expect(row.dataset.descriptionHtml).toBeUndefined();
  });

  test('writes description + raw html (raw falls back to description)', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { description: '<p>d</p>' });
    expect(row.descriptionHtml).toBe('<p>d</p>');
    expect(row.dataset.descriptionHtml).toBe('<p>d</p>');
    expect(row.dataset.descriptionRawHtml).toBe('<p>d</p>');
  });

  test('explicit description_raw_html is preserved distinctly', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { description: '<p>d</p>', description_raw_html: '<p>r</p>' });
    expect(row.dataset.descriptionHtml).toBe('<p>d</p>');
    expect(row.dataset.descriptionRawHtml).toBe('<p>r</p>');
  });

  test('missing description writes empty string (not skipped)', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { progress: 10 });
    expect(row.dataset.descriptionHtml).toBe('');
    expect(row.dataset.descriptionRawHtml).toBe('');
  });

  test('progress_html only written when non-null', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { description: 'd', progress_html: '<b>50%</b>' });
    expect(row.progressHtml).toBe('<b>50%</b>');
    expect(row.dataset.progressHtml).toBe('<b>50%</b>');

    const { row: row2 } = makeRow('2');
    updateRowFromData(row2, { description: 'd', progress_html: null });
    expect(row2.dataset.progressHtml).toBeUndefined();
  });

  test('progress written from own key; null clears dataset value', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { description: 'd', progress: 30 });
    expect(row.dataset.progressValue).toBe('30');

    // `?? ''` maps null/undefined to '', and setRowDatasetValue deletes on ''? no:
    // value '' is a string -> stored as ''.  null -> '' -> stored as ''.
    const { row: row2 } = makeRow('2');
    updateRowFromData(row2, { description: 'd', progress: null });
    expect(row2.dataset.progressValue).toBe('');
  });

  test('hasOwnProperty gating: absent keys leave dataset untouched', () => {
    const { row } = makeRow('1');
    row.dataset.originId = 'pre';
    row.dataset.contentType = 'pre';
    updateRowFromData(row, { description: 'd' });
    // origin_id / content_type not in payload -> not overwritten
    expect(row.dataset.originId).toBe('pre');
    expect(row.dataset.contentType).toBe('pre');
  });

  test('origin_id / content_type / markdown_source / markdown_editor round-trip', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, {
      description: 'd',
      origin_id: '77',
      content_type: 'markdown',
      markdown_source: '# s',
      markdown_editor: 'rich',
    });
    expect(row.dataset.originId).toBe('77');
    expect(row.dataset.contentType).toBe('markdown');
    expect(row.dataset.markdownSource).toBe('# s');
    expect(row.dataset.markdownEditor).toBe('rich');
  });

  test('has_children truthy sets attribute + property; falsy removes', () => {
    const { row } = makeRow('1');
    updateRowFromData(row, { description: 'd', has_children: true });
    expect(row.hasAttribute('has-children')).toBe(true);
    expect(row.hasChildren).toBe(true);

    updateRowFromData(row, { description: 'd', has_children: false });
    expect(row.hasAttribute('has-children')).toBe(false);
    expect(row.hasChildren).toBe(false);
  });

  test('calls requestUpdate when the row exposes it', () => {
    const { row } = makeRow('1');
    let called = 0;
    row.requestUpdate = () => { called += 1; };
    updateRowFromData(row, { description: 'd' });
    expect(called).toBe(1);
  });

  test('round-trip: updateRowFromData then inlinePayloadFromTree', () => {
    const { row, tree } = makeRow('50', { parentId: '2' });
    updateRowFromData(row, {
      description: '<p>body</p>',
      description_raw_html: '<p>raw</p>',
      progress: 40,
      origin_id: '5',
      content_type: 'markdown',
      markdown_source: '# md',
      markdown_editor: 'source',
    });
    expect(inlinePayloadFromTree(tree)).toEqual({
      id: '50',
      description: '<p>body</p>',
      description_raw_html: '<p>raw</p>',
      origin_id: '5',
      parent_id: '2',
      progress: 40,
      content_type: 'markdown',
      markdown_editor: 'source',
      markdown_source: '# md',
    });
  });
});
