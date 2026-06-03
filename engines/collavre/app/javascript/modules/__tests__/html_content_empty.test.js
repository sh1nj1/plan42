/**
 * @jest-environment jsdom
 */
import { isHtmlEmpty } from '../html_content_empty';

describe('isHtmlEmpty', () => {
  test('returns true for null/empty string', () => {
    expect(isHtmlEmpty('')).toBe(true);
    expect(isHtmlEmpty(null)).toBe(true);
    expect(isHtmlEmpty(undefined)).toBe(true);
  });

  test('returns true for whitespace-only HTML', () => {
    expect(isHtmlEmpty('<p>   </p>')).toBe(true);
    expect(isHtmlEmpty('<div><br></div>')).toBe(true);
  });

  test('returns false when there is text content', () => {
    expect(isHtmlEmpty('<p>hello</p>')).toBe(false);
  });

  test('returns false for image-only HTML', () => {
    expect(isHtmlEmpty('<p><img src="/blob/abc.png"></p>')).toBe(false);
  });

  test('returns false for action-text-attachment-only HTML', () => {
    expect(isHtmlEmpty(
      '<action-text-attachment sgid="abc" url="/blob" filename="file.png"></action-text-attachment>'
    )).toBe(false);
  });

  test('returns false for figure.attachment-only HTML (trix-style)', () => {
    expect(isHtmlEmpty(
      '<figure class="attachment attachment--file" data-trix-attachment=\'{"sgid":"abc"}\'></figure>'
    )).toBe(false);
  });

  test('returns false for [data-trix-attachment]-only HTML', () => {
    expect(isHtmlEmpty('<div data-trix-attachment=\'{"sgid":"x"}\'></div>')).toBe(false);
  });
});
