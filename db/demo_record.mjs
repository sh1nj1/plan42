/**
 * Collavre Demo Recording — Playwright
 * NO scrolling. AI streaming via server-side simulation.
 */
import { chromium } from 'playwright';
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BASE = 'http://localhost:53000';
const DARK_MODE = process.argv.includes('--dark');
const SUFFIX = DARK_MODE ? '-dark' : '';
const VIDEO_DIR = path.join(__dirname, `videos${SUFFIX}`);
const WORKTREE = `${process.env.HOME}/project/soonoh/plan42-worktree49`;

if (fs.existsSync(VIDEO_DIR)) fs.rmSync(VIDEO_DIR, { recursive: true });
fs.mkdirSync(VIDEO_DIR, { recursive: true });

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function ss(page, name) {
  await page.screenshot({ path: path.join(VIDEO_DIR, `${name}.png`) });
  console.log(`  📸 ${name}`);
}

// Clean up previous AI simulation comments
function cleanupAiComments() {
  const { execSync } = await_import_workaround();
  try {
    execSync(`cd ${WORKTREE} && bin/rails runner "Collavre::Comment.where('content LIKE ?', '%스프린트%').destroy_all"`, { timeout: 15000, stdio: 'pipe' });
  } catch {}
}

function await_import_workaround() {
  return require('child_process');
}

async function run() {
  // Cleanup
  try {
    const { execSync } = await import('child_process');
    execSync(`cd ${WORKTREE} && bin/rails runner "Collavre::Comment.where('content LIKE ? OR content LIKE ?', '%스프린트%', '%분석 중%').destroy_all"`, { timeout: 15000, stdio: 'pipe' });
    console.log('🧹 Cleaned up previous AI comments');
  } catch {}

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 960, height: 540 },
    recordVideo: { dir: VIDEO_DIR, size: { width: 960, height: 540 } },
    locale: 'ko-KR',
    colorScheme: DARK_MODE ? 'dark' : 'light',
  });

  const page = await context.newPage();
  page.setDefaultTimeout(10000);

  // ════════════════════════════════════════
  // LOGIN
  // ════════════════════════════════════════
  console.log('→ Login');
  await page.goto(`${BASE}/session/new`);
  await page.waitForSelector('#email');
  await page.fill('#email', 'pm@collabre.dev');
  await page.fill('#password', 'demo1234');
  await page.click('#sign-in-submit');
  await page.waitForNavigation({ timeout: 15000 }).catch(() => {});
  await sleep(2000);
  console.log(`  URL: ${page.url()}`);

  // ════════════════════════════════════════
  // SCENE 1: 루트 크리에이티브 목록 (홈 탭)
  // ════════════════════════════════════════
  console.log('→ Scene 1: 루트 목록');
  await sleep(2000);
  await ss(page, '01-root');

  // ════════════════════════════════════════
  // SCENE 2: v2.0 프로젝트 → 트리 전개
  // ════════════════════════════════════════
  console.log('→ Scene 2: 트리 전개');
  const v2Row = page.locator('creative-tree-row').filter({ hasText: '콜라브 v2.0 릴리즈' }).first();
  if (await v2Row.isVisible().catch(() => false)) {
    await v2Row.locator('.description, [part="description"]').first().click().catch(() => v2Row.click());
    await sleep(2500);
  }
  await ss(page, '02-v2-project');

  const expandBtn = page.locator('#expand-all-btn');
  if (await expandBtn.isVisible().catch(() => false)) {
    await expandBtn.click();
    await sleep(2500);
  }
  await ss(page, '03-tree-expanded');

  // ════════════════════════════════════════
  // SCENE 3: 채팅 팝업 & 토픽 전환
  // ════════════════════════════════════════
  console.log('→ Scene 3: 채팅 & 토픽');
  const commentBtn = page.locator('creative-tree-row').filter({ hasText: '콜라브 v2.0 릴리즈' }).locator('.comments-btn').first();
  if (await commentBtn.isVisible().catch(() => false)) {
    await commentBtn.click();
    await sleep(2500);
  }
  await ss(page, '04-chat-popup');

  const popup = page.locator('#comments-popup');

  // 코드 리뷰 토픽
  const reviewTopic = popup.locator('text=코드 리뷰').first();
  if (await reviewTopic.isVisible().catch(() => false)) {
    await reviewTopic.click();
    await sleep(2000);
    const msgs = popup.locator('.messages, .comments-list, [data-comments--list-target]').first();
    if (await msgs.isVisible().catch(() => false)) {
      await msgs.evaluate(el => el.scrollTo({ top: el.scrollHeight }));
      await sleep(1000);
    }
  }
  await ss(page, '05-code-review');

  // 디자인 논의 토픽
  const designTopic = popup.locator('text=디자인 논의').first();
  if (await designTopic.isVisible().catch(() => false)) {
    await designTopic.click();
    await sleep(2000);
  }
  await ss(page, '06-design');

  // ════════════════════════════════════════
  // SCENE 4: AI 에이전트 — @Vrex 멘션 + 실시간 스트리밍
  // ════════════════════════════════════════
  console.log('→ Scene 4: AI 에이전트 스트리밍');

  // 현재 토픽(디자인 논의)에서 바로 AI 멘션 — 토픽 전환 없음

  // 댓글 입력
  const textarea = popup.locator('textarea[name="comment[content]"]').first();
  const form = popup.locator('#new-comment-form');

  // 폼이 숨겨져있으면 표시
  if (!(await form.isVisible().catch(() => false))) {
    await page.evaluate(() => {
      const f = document.getElementById('new-comment-form');
      if (f) f.style.display = '';
    });
    await sleep(500);
  }

  if (await textarea.isVisible().catch(() => false)) {
    await textarea.click();
    await sleep(300);
    await textarea.type('@Vrex: 이번 스프린트에서 가장 우선순위 높은 작업이 뭐야?', { delay: 40 });
    await sleep(1000);
    await ss(page, '07-ai-typing');

    // Submit comment
    await page.keyboard.press('Enter');
    await sleep(2000);
    await ss(page, '08-ai-submitted');

    // Create AI response in the SAME topic as the user's comment
    console.log('  Creating AI response...');
    const { execSync } = await import('child_process');
    try {
      execSync(`cd ${WORKTREE} && bin/rails runner '
        vrex = Collavre::User.find_by(email: "ai-agent@collabre.dev")
        # Find the latest @Vrex comment to get its topic
        trigger = Collavre::Comment.where("content LIKE ?", "%스프린트%우선순위%").where.not(user: vrex).order(created_at: :desc).first
        if trigger
          trigger.creative.comments.create!(
            user: vrex,
            topic: trigger.topic,
            content: "이번 스프린트 우선순위를 분석해보겠습니다.\\n\\n**1순위: API v2 개발** (75% 완료)\\n- 인증 미들웨어가 핵심 블로커\\n- 프론트엔드 리팩토링이 이에 의존\\n\\n**2순위: 디자인 시스템 리뉴얼** (30% 완료)\\n- 컴포넌트 라이브러리 마이그레이션 필요\\n\\n**3순위: 성능 최적화**\\n- 현재 p95 응답시간 개선 여지 있음\\n\\n📊 전체 스프린트 진행률: 64%"
          )
          puts "OK topic:#{trigger.topic.name}"
        else
          puts "TRIGGER NOT FOUND"
        end
      '`, { timeout: 15000, stdio: 'pipe' });
      console.log('  AI response created');
    } catch (e) {
      console.log(`  AI creation error`);
    }

    // Brief pause for "thinking" effect in video
    await sleep(2000);
    await ss(page, '09-ai-thinking');

    // Close and re-open chat to show the AI response
    await page.keyboard.press('Escape');
    await sleep(300);
    await page.evaluate(() => {
      const p = document.getElementById('comments-popup');
      if (p) p.style.display = 'none';
    });
    await sleep(500);

    // Re-open chat on the same creative
    await page.evaluate(() => {
      const p = document.getElementById('comments-popup');
      if (p) p.style.display = '';
    });
    const commentBtnReopen = page.locator('creative-tree-row').filter({ hasText: '콜라브 v2.0 릴리즈' }).locator('.comments-btn').first();
    if (await commentBtnReopen.isVisible().catch(() => false)) {
      await commentBtnReopen.click();
      await sleep(2000);
    }

    // The @Vrex comment was posted in whatever topic was active (디자인 논의)
    // Switch to that topic to see the AI response
    const aiTopicTab = popup.locator('text=디자인 논의').first();
    if (await aiTopicTab.isVisible().catch(() => false)) {
      await aiTopicTab.click();
      await sleep(1500);
    }

    // Scroll to bottom to see Vrex's response
    const msgsArea = popup.locator('.messages, .comments-list, [data-comments--list-target]').first();
    if (await msgsArea.isVisible().catch(() => false)) {
      await msgsArea.evaluate(el => el.scrollTo({ top: el.scrollHeight }));
      await sleep(2000);
    }
    await ss(page, '10-ai-response');
    await sleep(3000);
    await ss(page, '11-ai-final');
  } else {
    console.log('  ⚠️ Textarea not visible');
  }

  // ════════════════════════════════════════
  // SCENE 5: 컨텍스트 시스템
  // ════════════════════════════════════════
  console.log('→ Scene 5: 컨텍스트');
  await page.keyboard.press('Escape');
  await sleep(300);
  await page.evaluate(() => {
    const p = document.getElementById('comments-popup');
    if (p) p.style.display = 'none';
  });
  await sleep(500);

  const apiRow = page.locator('creative-tree-row').filter({ hasText: 'API v2 개발' }).first();
  if (await apiRow.isVisible().catch(() => false)) {
    await apiRow.click({ force: true });
    await sleep(2500);
    await ss(page, '14-api-v2');
  }

  await page.evaluate(() => {
    const p = document.getElementById('comments-popup');
    if (p) p.style.display = '';
  });
  const apiCommentBtn = page.locator('creative-tree-row').filter({ hasText: 'API v2 개발' }).locator('.comments-btn').first();
  if (await apiCommentBtn.isVisible().catch(() => false)) {
    await apiCommentBtn.click({ force: true });
    await sleep(2500);
  }
  await ss(page, '15-context');

  // ════════════════════════════════════════
  // FINAL
  // ════════════════════════════════════════
  console.log('→ Final');
  await page.goto(`${BASE}/`);
  await sleep(2500);
  await ss(page, '16-final');

  const videoPath = await page.video().path();
  await context.close();
  await browser.close();

  console.log(`\n✅ Video: ${videoPath}`);
  const files = fs.readdirSync(VIDEO_DIR).sort();
  console.log(`   Files: ${files.join(', ')}`);
}

run().catch(err => {
  console.error('❌ Failed:', err.message);
  process.exit(1);
});
