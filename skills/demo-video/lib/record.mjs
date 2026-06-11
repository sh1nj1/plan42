/**
 * Generic, scenario-driven demo recorder for Collavre.
 *
 * Reads a declarative YAML scenario, drives one viewport + theme with
 * Playwright, injects scripted AI turns into the local fake LLM (so a real
 * @mention animates the real streaming UI), records a .webm, then post-processes
 * to .mp4 + poster with ffmpeg.
 *
 * Usage:
 *   node record.mjs --scenario <path> [--theme light|dark] [--size landing]
 *                   [--base http://localhost:53000] [--llm http://127.0.0.1:8730]
 *                   [--out <dir>] [--no-post] [--speed 2]
 */
import { chromium } from 'playwright';
import { spawnSync } from 'child_process';
import { parse as parseYaml } from 'yaml';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ── arg parsing ──────────────────────────────────────────────────────────
function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith('--') ? v : true;
}
const SCENARIO = arg('scenario');
const THEME = arg('theme', 'light');
const SIZE = arg('size', null);
const BASE = (arg('base', 'http://localhost:53000') || '').replace(/\/$/, '');
const LLM = (arg('llm', 'http://127.0.0.1:8730') || '').replace(/\/$/, '');
const OUT = arg('out', path.join(__dirname, '..', 'output'));
const NO_POST = arg('no-post', false) === true;
const SPEED = parseFloat(arg('speed', '2')) || 2;

if (!SCENARIO) {
  console.error('error: --scenario <path> is required');
  process.exit(2);
}

const SIZES = {
  landing: { width: 1280, height: 720 },
  wide: { width: 1920, height: 1080 },
  square: { width: 1080, height: 1080 },
  portrait: { width: 1080, height: 1920 },
};

const scenario = parseYaml(fs.readFileSync(SCENARIO, 'utf8'));
const sizeKey = SIZE || scenario.viewport || 'landing';
const size = SIZES[sizeKey] || SIZES.landing;
const name = scenario.name || path.basename(SCENARIO).replace(/\.ya?ml$/, '');
const suffix = THEME === 'dark' ? '-dark' : '';
const SHOT_DIR = path.join(OUT, `${name}${suffix}-shots`);
const VIDEO_DIR = path.join(OUT, `${name}${suffix}-raw`);

// OUT is shared across themes (run.sh records light then dark into the same
// dir), so only reset the per-theme raw/shot dirs — wiping OUT here would
// delete the previous theme's .mp4/poster.
fs.mkdirSync(OUT, { recursive: true });
for (const d of [SHOT_DIR, VIDEO_DIR]) {
  if (fs.existsSync(d)) fs.rmSync(d, { recursive: true, force: true });
  fs.mkdirSync(d, { recursive: true });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── fake LLM injection ───────────────────────────────────────────────────
async function llmReset() {
  await fetch(`${LLM}/reset`, { method: 'POST' }).catch(() => {});
}
async function llmInject(responses) {
  if (!responses || !responses.length) return;
  await fetch(`${LLM}/inject`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ responses }),
  }).catch((e) => console.warn(`  ⚠️ inject failed: ${e.message}`));
}

// ── step interpreter ─────────────────────────────────────────────────────
function stepKind(step) {
  if (typeof step === 'string') return [step, true];
  const key = Object.keys(step)[0];
  return [key, step[key]];
}

async function shot(page, label) {
  const file = path.join(SHOT_DIR, `${label}.png`);
  await page.screenshot({ path: file }).catch(() => {});
  console.log(`  📸 ${label}`);
}

function rowLocator(page, text) {
  return page.locator('creative-tree-row').filter({ hasText: text }).first();
}

async function ensureFormVisible(page) {
  await page.evaluate(() => {
    const f = document.getElementById('new-comment-form');
    if (f) f.style.display = '';
  });
}

// Wait until the latest AI comment finishes streaming.
//
// Completion is detected when (a) the last AI comment's text has stopped
// growing and (b) the typing indicator (`#typing-indicator`, which shows
// "<agent> ..." while a reply streams) has cleared. The typing indicator is
// the authoritative end-of-stream signal; the text-stability check guards
// against a momentary empty indicator between chunks.
async function waitStream(page, timeoutMs = 40000) {
  const start = Date.now();
  await page
    .waitForSelector('#comments-list .comment-item[data-ai-user="true"]', { timeout: 15000 })
    .catch(() => {});
  let lastLen = -1;
  let stable = 0;
  while (Date.now() - start < timeoutMs) {
    const state = await page
      .evaluate(() => {
        const items = document.querySelectorAll(
          '#comments-list .comment-item[data-ai-user="true"]'
        );
        const last = items[items.length - 1];
        const typing = document.getElementById('typing-indicator');
        return {
          len: last ? (last.innerText || '').trim().length : 0,
          typing: typing ? (typing.innerText || '').trim().length > 0 : false,
        };
      })
      .catch(() => ({ len: 0, typing: false }));
    if (state.len > 15 && state.len === lastLen && !state.typing) {
      stable += 1;
      if (stable >= 2) return; // ~1s settled with no typing indicator
    } else {
      stable = 0;
    }
    lastLen = state.len;
    await sleep(500);
  }
  // The AI streamed reply is the core of the demo. If it never appears or never
  // settles, the recording is worthless — throw so the step loop marks the run
  // as failed (exit non-zero) instead of publishing a video missing its payload.
  throw new Error(
    `waitStream timed out after ${timeoutMs}ms — no settled AI response ` +
      `(check mention routing, :feedback permission, ActionCable, or fake LLM)`
  );
}

async function runStep(page, step) {
  const [kind, val] = stepKind(step);
  switch (kind) {
    case 'login': {
      await page.goto(`${BASE}/session/new`);
      await page.waitForSelector('#email');
      await page.fill('#email', val.email);
      await page.fill('#password', val.password);
      await page.click('#sign-in-submit');
      await page.waitForLoadState('networkidle').catch(() => {});
      await sleep(1500);
      return;
    }
    case 'goto':
      await page.goto(`${BASE}${val}`);
      await sleep(800);
      return;
    case 'wait':
      await sleep(Number(val) || 0);
      return;
    case 'shot':
      await shot(page, val);
      return;
    case 'click':
      await page.locator(val).first().click({ timeout: 8000 }).catch((e) =>
        console.log(`  ⚠️ click ${val}: ${e.message.split('\n')[0]}`)
      );
      return;
    case 'click_row': {
      const row = rowLocator(page, val);
      const desc = row.locator('.description, [part="description"]').first();
      await (await desc.isVisible().catch(() => false)
        ? desc.click().catch(() => row.click({ force: true }))
        : row.click({ force: true }));
      return;
    }
    case 'open_chat': {
      const btn = rowLocator(page, val).locator('.comments-btn').first();
      await btn.click({ force: true, timeout: 8000 }).catch((e) =>
        console.log(`  ⚠️ open_chat ${val}: ${e.message.split('\n')[0]}`)
      );
      await page.waitForSelector('#comments-popup', { timeout: 8000 }).catch(() => {});
      return;
    }
    case 'topic': {
      const tab = page.locator('#comment-topics').locator(`text=${val}`).first();
      await tab.click({ timeout: 6000 }).catch((e) =>
        console.log(`  ⚠️ topic ${val}: ${e.message.split('\n')[0]}`)
      );
      await sleep(1200);
      return;
    }
    case 'type': {
      const el = page.locator(val.selector).first();
      await el.click().catch(() => {});
      await el.type(val.text, { delay: val.delay ?? 35 });
      return;
    }
    case 'mention_ai': {
      await ensureFormVisible(page);
      const textarea = page
        .locator('#new-comment-form textarea, textarea[name="comment[content]"]')
        .first();
      await textarea.click().catch(() => {});
      await textarea.type(val.text, { delay: val.delay ?? 35 });
      await sleep(600);
      if (val.shot) await shot(page, val.shot);
      await page.keyboard.press('Enter');
      return;
    }
    case 'wait_stream':
      await waitStream(page, (val && val.timeout) || 40000);
      return;
    case 'scroll_bottom': {
      const sel = (val && val.selector) || '#comments-list';
      await page
        .locator(sel)
        .first()
        .evaluate((el) => el.scrollTo({ top: el.scrollHeight }))
        .catch(() => {});
      return;
    }
    case 'press':
      await page.keyboard.press(val);
      return;
    case 'js':
      await page.evaluate((code) => eval(code), val); // escape hatch
      return;
    default:
      console.log(`  ⚠️ unknown step: ${kind}`);
  }
}

// ── ffmpeg post ──────────────────────────────────────────────────────────
function postProcess(rawPath) {
  const mp4 = path.join(OUT, `${name}${suffix}.mp4`);
  const poster = path.join(OUT, `${name}${suffix}-poster.jpg`);
  const pts = (1 / SPEED).toFixed(4);
  const vf = `setpts=${pts}*PTS,scale=${size.width}:${size.height}:flags=lanczos`;
  const r = spawnSync(
    'ffmpeg',
    ['-y', '-i', rawPath, '-vf', vf, '-c:v', 'libx264', '-preset', 'slow',
     '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an', mp4],
    { stdio: 'pipe' }
  );
  if (r.status !== 0) {
    console.error('  ❌ ffmpeg failed:', (r.stderr || '').toString().split('\n').slice(-4).join('\n'));
    return null;
  }
  spawnSync('ffmpeg', ['-y', '-i', mp4, '-vframes', '1', '-q:v', '2', poster], { stdio: 'pipe' });
  const kb = (fs.statSync(mp4).size / 1024).toFixed(0);
  console.log(`  🎬 ${mp4} (${kb} KB)`);
  console.log(`  🖼  ${poster}`);
  return mp4;
}

// ── main ─────────────────────────────────────────────────────────────────
async function main() {
  console.log(`\n▶ scenario=${name} theme=${THEME} size=${sizeKey} (${size.width}x${size.height})`);
  await llmReset();
  await llmInject(scenario.ai_turns || scenario.aiTurns);

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: size,
    recordVideo: { dir: VIDEO_DIR, size },
    locale: scenario.locale || 'ko-KR',
    colorScheme: THEME === 'dark' ? 'dark' : 'light',
    deviceScaleFactor: 2,
  });
  const page = await context.newPage();
  page.setDefaultTimeout(10000);

  // A thrown step (missing selector, changed login flow, …) must fail the run:
  // run.sh keys off this process's exit status, so swallowing the error would
  // report a broken scenario as a successful demo video. We still finalize the
  // partial recording below for debugging, then exit non-zero.
  let stepError = null;
  try {
    for (const step of scenario.steps || []) {
      await runStep(page, step);
    }
  } catch (e) {
    stepError = e;
    console.error('  ❌ step error:', e.message);
  }

  const video = page.video();
  await context.close();
  await browser.close();

  let rawPath = null;
  if (video) rawPath = await video.path().catch(() => null);
  if (!rawPath) {
    const files = fs.readdirSync(VIDEO_DIR).filter((f) => f.endsWith('.webm'));
    if (files.length) rawPath = path.join(VIDEO_DIR, files[0]);
  }
  if (!rawPath) {
    console.error('  ❌ no video produced');
    process.exit(1);
  }
  console.log(`  📼 raw: ${rawPath}`);
  if (!NO_POST) postProcess(rawPath);

  if (stepError) {
    console.error('  ❌ recording failed: a scenario step threw — output is partial');
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('❌ fatal:', e);
  process.exit(1);
});
