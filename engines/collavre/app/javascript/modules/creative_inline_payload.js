// Inline creative payload mapping cluster extracted from creative_row_editor.js
// (slice 3 of the god-file decomposition).
//
// These two functions are the inverse pair over the "inline creative payload"
// shape that drives instant/optimistic UI: `inlinePayloadFromTree` reads a
// payload OUT of a rendered tree row's dataset, and `updateRowFromData` writes a
// server/API payload INTO a row's dataset + attributes. Both depend only on their
// arguments (plus the pure DOM helpers below and browser globals) — neither
// captures editor closure state, and neither uses timers or `this`. Behavior is
// identical to the original inline versions.
import {
  treeRowElement,
  hasDatasetValue,
  setRowDatasetValue,
} from './creative_row_editor_helpers'

export function updateRowFromData(row, data) {
  if (!row || !data) return;
  const descriptionHtml = data.description || '';
  const rawHtml = data.description_raw_html || descriptionHtml;
  row.descriptionHtml = descriptionHtml;
  setRowDatasetValue(row, 'descriptionHtml', descriptionHtml);
  setRowDatasetValue(row, 'descriptionRawHtml', rawHtml);
  if (data.progress_html != null) {
    row.progressHtml = data.progress_html;
    setRowDatasetValue(row, 'progressHtml', data.progress_html);
  }
  if (Object.prototype.hasOwnProperty.call(data, 'progress')) {
    setRowDatasetValue(row, 'progressValue', data.progress ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'origin_id')) {
    setRowDatasetValue(row, 'originId', data.origin_id ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'content_type')) {
    setRowDatasetValue(row, 'contentType', data.content_type ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'markdown_source')) {
    setRowDatasetValue(row, 'markdownSource', data.markdown_source ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'markdown_editor')) {
    setRowDatasetValue(row, 'markdownEditor', data.markdown_editor ?? '');
  }
  if (Object.prototype.hasOwnProperty.call(data, 'has_children')) {
    if (data.has_children) {
      row.setAttribute('has-children', '');
      row.hasChildren = true;
    } else {
      row.removeAttribute('has-children');
      row.hasChildren = false;
    }
  }
  if (typeof row.requestUpdate === 'function') {
    row.requestUpdate();
  }
}

export function inlinePayloadFromTree(tree) {
  if (!tree) return null;
  const row = treeRowElement(tree);
  if (!row) return null;

  // Relax validation - allow loading with partial data for instant UI
  const hasDescription = hasDatasetValue(row, 'descriptionRawHtml') || hasDatasetValue(row, 'descriptionHtml');
  const hasProgress = hasDatasetValue(row, 'progressValue');

  // Only require ID to be present
  const id = tree.dataset?.id;
  if (!id) return null;

  const rawHtml = hasDatasetValue(row, 'descriptionRawHtml') ? row.dataset.descriptionRawHtml : row.dataset.descriptionHtml || '';
  const description = row.dataset.descriptionHtml || rawHtml || '';
  const progressValue = hasProgress ? Number(row.dataset.progressValue ?? 0) : 0;
  const parentId = tree.dataset?.parentId || '';

  return {
    id: id,
    description,
    description_raw_html: rawHtml,
    origin_id: row.dataset?.originId || '',
    parent_id: parentId,
    progress: Number.isNaN(progressValue) ? 0 : progressValue,
    content_type: row.dataset?.contentType || null,
    markdown_editor: row.dataset?.markdownEditor || null,
    markdown_source: row.dataset?.markdownSource || null
  };
}
