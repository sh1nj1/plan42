const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

test('global controls retain theme, focus, and compact geometry', async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 375, height: 812 } });
    const files = [
      'engines/collavre/app/assets/stylesheets/collavre/design_tokens.css',
      'engines/collavre/app/assets/stylesheets/collavre/popup.css',
      'engines/collavre/app/assets/stylesheets/collavre/comments_popup.css',
      'app/assets/stylesheets/application.css'
    ];
    await page.setContent('<style>' + files.map(f => readFileSync(f, 'utf8')).join('\n') + '</style><body><form class="stacked-form"><input class="topic-input"><input class="topic-edit-input"><input type="submit" class="primary-action-button" value="Save 저장"><button class="secondary-action-button">Cancel 취소</button></form><span class="text-muted">Help</span><small class="form-text">Help</small><div class="comments-popup-actions"><button class="popup-close-btn">×</button></div><form id="new-comment-form" style="width:280px"><textarea></textarea></form></body>');
    for (const theme of ['light-mode', 'dark-mode', 'system']) {
      await page.emulateMedia({ colorScheme: theme === 'system' ? 'dark' : 'light' });
      await page.evaluate(t => document.body.className = t === 'system' ? '' : t, theme);
      for (const selector of ['.topic-input', '.topic-edit-input']) {
        await page.locator(selector).focus();
        const style = await page.locator(selector).evaluate(el => {
          const s = getComputedStyle(el);
          return [s.borderLeftWidth, s.borderRightWidth, s.boxShadow];
        });
        assert.deepEqual(style, ['1px', '1px', 'none']);
      }
      const geometry = await page.evaluate(() => {
        const close = document.querySelector('.popup-close-btn').getBoundingClientRect();
        const area = document.querySelector('textarea').getBoundingClientRect();
        const primary = document.querySelector('.primary-action-button');
        return {
          close: [close.width, close.height],
          area: area.width,
          height: primary.getBoundingClientRect().height,
          bg: getComputedStyle(primary).backgroundColor,
          muted: getComputedStyle(document.querySelector('.text-muted')).color,
          helper: getComputedStyle(document.querySelector('.form-text')).color,
          secondary: document.querySelector('.secondary-action-button').getBoundingClientRect().height
        };
      });
      assert.deepEqual(geometry.close, [28, 28]);
      assert.equal(geometry.area, 280);
      assert.ok(geometry.height >= 36);
      assert.equal(geometry.height, geometry.secondary);
      assert.equal(geometry.bg, 'rgb(35, 122, 59)');
      assert.equal(geometry.muted, geometry.helper);
      assert.equal(geometry.muted, theme === 'light-mode' ? 'rgb(102, 102, 102)' : 'rgb(170, 170, 170)');
      await page.locator('.primary-action-button').focus();
      assert.equal(await page.locator('.primary-action-button').evaluate(e => getComputedStyle(e).outlineStyle), 'solid');
    }
  } finally {
    await browser.close();
  }
});
