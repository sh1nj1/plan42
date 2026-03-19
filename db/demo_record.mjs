/**
 * Demo recording script — Playwright
 * Records a short demo showing 4 key features of Collavre:
 *   1. Hierarchical Creatives (tree view)
 *   2. AI Agent as Teammate (chat with Vrex)
 *   3. Context System
 *   4. Real-time Chat & Topics
 *
 * Usage: npx playwright test --config db/demo_record.config.mjs
 *   or:  node db/demo_record.mjs
 */

import { chromium } from 'playwright';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASE = 'http://localhost:53000';
const VIDEO_DIR = path.join(__dirname, '..', 'tmp', 'demo-videos');

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function run() {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    recordVideo: { dir: VIDEO_DIR, size: { width: 1440, height: 900 } },
    locale: 'ko-KR',
  });

  const page = await context.newPage();

  // ─── Login ───
  await page.goto(`${BASE}/session/new`);
  await page.fill('input[name="email"]', 'pm@collabre.dev');
  await page.fill('input[name="password"]', 'demo1234');
  await page.click('button[type="submit"], input[type="submit"]');
  await page.waitForURL('**/creatives**', { timeout: 10000 });
  await sleep(1500);

  // ─── 1. Hierarchical Creatives — Tree View ───
  // Click on "콜라브 v2.0 릴리즈"
  const v2Link = page.locator('text=콜라브 v2.0 릴리즈').first();
  if (await v2Link.isVisible()) {
    await v2Link.click();
    await sleep(2000);
  }

  // Expand children — click on sub-creatives to show tree
  const apiLink = page.locator('text=API v2 개발').first();
  if (await apiLink.isVisible()) {
    await apiLink.click();
    await sleep(1500);
  }

  // Scroll down slowly to show tree structure
  await page.mouse.wheel(0, 300);
  await sleep(1500);
  await page.mouse.wheel(0, -300);
  await sleep(1000);

  // Go back to v2 root
  await v2Link.click({ timeout: 5000 }).catch(() => {});
  await sleep(1500);

  // ─── 2 & 4. Chat & Topics + AI Agent ───
  // Look for chat/comments area — click topic tabs
  const topicGeneral = page.locator('text=일반').first();
  if (await topicGeneral.isVisible()) {
    await topicGeneral.click();
    await sleep(1500);
  }

  // Scroll through chat to show AI agent conversation
  const chatArea = page.locator('.comments-container, .chat-messages, [data-controller*="comment"], .topic-messages').first();
  if (await chatArea.isVisible()) {
    await chatArea.evaluate(el => el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }));
    await sleep(2000);
  }

  // Switch to 코드 리뷰 topic
  const topicReview = page.locator('text=코드 리뷰').first();
  if (await topicReview.isVisible()) {
    await topicReview.click();
    await sleep(2000);

    // Scroll to see Vrex's code review comment
    const chatArea2 = page.locator('.comments-container, .chat-messages, [data-controller*="comment"], .topic-messages').first();
    if (await chatArea2.isVisible()) {
      await chatArea2.evaluate(el => el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }));
    }
    await sleep(2000);
  }

  // ─── 3. Context System ───
  // Navigate to API v2 개발 creative to show context
  await page.goto(`${BASE}/creatives`);
  await sleep(1500);

  const apiCreative = page.locator('text=API v2 개발').first();
  if (await apiCreative.isVisible()) {
    await apiCreative.click();
    await sleep(2000);
  }

  // Look for context indicator
  const contextBtn = page.locator('[data-context], .context-badge, text=컨텍스트, text=context').first();
  if (await contextBtn.isVisible({ timeout: 2000 }).catch(() => false)) {
    await contextBtn.click();
    await sleep(2000);
  }

  // ─── Final overview — back to root ───
  await page.goto(`${BASE}/creatives`);
  await sleep(2000);

  // Slowly scroll the whole page
  await page.mouse.wheel(0, 400);
  await sleep(1500);

  // Done
  await sleep(1000);
  await context.close();
  await browser.close();

  console.log(`\nVideo saved to: ${VIDEO_DIR}`);
  console.log('Post-process with ffmpeg to create final demo.');
}

run().catch(err => {
  console.error('Recording failed:', err);
  process.exit(1);
});
