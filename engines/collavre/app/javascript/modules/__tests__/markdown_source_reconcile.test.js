/**
 * @jest-environment jsdom
 */
import { reconcileMarkdownSource } from '../markdown_source_reconcile';

const DATA_URI = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
const BLOB_PATH = '/rails/active_storage/blobs/redirect/abc123def/image.png';
const DATA_URI_2 = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
const BLOB_PATH_2 = '/rails/active_storage/blobs/redirect/xyz789/two.gif';

describe('reconcileMarkdownSource', () => {
  test('returns rewritten value when current still equals saved', () => {
    const saved = `Hello ![pic](${DATA_URI}) world`;
    const rewritten = `Hello ![pic](${BLOB_PATH}) world`;
    expect(reconcileMarkdownSource(saved, rewritten, saved)).toBe(rewritten);
  });

  test('returns null when no rewrites happened', () => {
    expect(reconcileMarkdownSource('a', 'a', 'a')).toBe(null);
  });

  test('returns null when saved has no data URI and current diverged from saved', () => {
    expect(reconcileMarkdownSource('saved', 'rewritten', 'user typed something else')).toBe(null);
  });

  test('merges substitutions when user typed AFTER the data URI mid-save', () => {
    const saved = `![pic](${DATA_URI})`;
    const rewritten = `![pic](${BLOB_PATH})`;
    const current = `![pic](${DATA_URI})\n\nNew paragraph user typed during save.`;
    const expected = `![pic](${BLOB_PATH})\n\nNew paragraph user typed during save.`;
    expect(reconcileMarkdownSource(saved, rewritten, current)).toBe(expected);
  });

  test('merges substitutions when user typed BEFORE the data URI mid-save', () => {
    const saved = `start ![pic](${DATA_URI}) end`;
    const rewritten = `start ![pic](${BLOB_PATH}) end`;
    const current = `inserted at top\n\nstart ![pic](${DATA_URI}) end`;
    const expected = `inserted at top\n\nstart ![pic](${BLOB_PATH}) end`;
    expect(reconcileMarkdownSource(saved, rewritten, current)).toBe(expected);
  });

  test('handles multiple data URIs in a single save', () => {
    const saved = `A ![1](${DATA_URI}) B ![2](${DATA_URI_2}) C`;
    const rewritten = `A ![1](${BLOB_PATH}) B ![2](${BLOB_PATH_2}) C`;
    const current = `A ![1](${DATA_URI}) B ![2](${DATA_URI_2}) C\n\nextra text`;
    const expected = `A ![1](${BLOB_PATH}) B ![2](${BLOB_PATH_2}) C\n\nextra text`;
    expect(reconcileMarkdownSource(saved, rewritten, current)).toBe(expected);
  });

  test('handles reference-style data URI definitions', () => {
    const saved = `![pic][p]\n\n[p]: ${DATA_URI}`;
    const rewritten = `![pic][p]\n\n[p]: ${BLOB_PATH}`;
    const current = `![pic][p]\n\nuser typed more\n\n[p]: ${DATA_URI}`;
    const expected = `![pic][p]\n\nuser typed more\n\n[p]: ${BLOB_PATH}`;
    expect(reconcileMarkdownSource(saved, rewritten, current)).toBe(expected);
  });

  test('returns null when user removed the data URI before response', () => {
    const saved = `![pic](${DATA_URI})`;
    const rewritten = `![pic](${BLOB_PATH})`;
    const current = 'user wiped everything';
    expect(reconcileMarkdownSource(saved, rewritten, current)).toBe(null);
  });

  test('returns null on non-string inputs', () => {
    expect(reconcileMarkdownSource(null, 'a', 'a')).toBe(null);
    expect(reconcileMarkdownSource('a', null, 'a')).toBe(null);
    expect(reconcileMarkdownSource('a', 'a', null)).toBe(null);
  });
});
