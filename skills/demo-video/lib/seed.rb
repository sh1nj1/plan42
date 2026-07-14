# Demo seed for the demo-video skill.
# Run: bin/rails runner skills/demo-video/lib/seed.rb
#
# Differs from db/demo_seed.rb in one critical way: the AI teammate "Vrex" is
# configured as a real OpenAI-vendor agent pointed at the local fake LLM server
# (DEMO_LLM_URL). A genuine `@Vrex:` mention then drives the real Collavre
# streaming pipeline against scripted responses — no rails-runner insert trick.
#
# Two scenarios, selected with DEMO_SCENARIO:
#
#   landing  (default, Korean)  A fully-populated workspace. Everything the video
#                               shows already exists; the recording is a tour.
#
#   launch   (English)          A near-empty workspace. The video BUILDS the tree
#                               on camera (markdown import), pins context, mentions
#                               the agent, and checks tasks off — so the claim
#                               "nothing was ever copied" is demonstrated rather
#                               than asserted. Seeds only what must pre-exist: the
#                               handbook to pin, and an empty project root that
#                               already shares :feedback with Vrex.
#
# Env:
#   DEMO_LLM_URL   OpenAI-compatible base url for Vrex (default http://127.0.0.1:8730/v1)
#   DEMO_SCENARIO  landing | launch  (default: landing)
#   DEMO_THEME     light | dark      (forces the login user's theme)
#   DEMO_LOCALE    en | ko           (forces the login user's locale AND the language
#                                     the seeded content is written in; defaults to the
#                                     language each scenario was originally authored in)

llm_url  = ENV.fetch("DEMO_LLM_URL", "http://127.0.0.1:8730/v1")
scenario = ENV.fetch("DEMO_SCENARIO", "landing")

unless %w[landing launch].include?(scenario)
  abort "seed: unknown DEMO_SCENARIO=#{scenario.inspect} (expected landing|launch)"
end

# The launch video ships in both languages, and the scenario clicks rows *by their
# text* — so this is not just chrome. Whatever language the seed writes its
# creatives in is the language launch.yml's `strings:` table must resolve to, or
# the recording fails on a missing row rather than shipping a mixed-language demo.
locale = ENV.fetch("DEMO_LOCALE") { scenario == "launch" ? "en" : "ko" }
unless %w[en ko].include?(locale)
  abort "seed: unknown DEMO_LOCALE=#{locale.inspect} (expected en|ko)"
end
ko = locale == "ko"

def html(text)
  "<div><p class=\"lexical-paragraph\"><span style=\"white-space:pre-wrap;\">#{text}</span></p></div>"
end

# Multi-paragraph body — used for the handbook, whose whole point is that it has
# real content an agent can quote back at you.
def html_lines(lines)
  body = lines.map do |line|
    "<p class=\"lexical-paragraph\"><span style=\"white-space:pre-wrap;\">#{line}</span></p>"
  end.join
  "<div>#{body}</div>"
end

pw = "demo1234"

# The team reads in the language of the take, not of the scenario: a Korean
# recording with a roster of English names looks like a translation of someone
# else's product. Emails are shared across scenarios and locales — the cleanup
# below scopes on them, so switching either must not strand the other's creatives.
users =
  if !ko
    {
      ceo:      { name: "Dana Reed",     email: "ceo@collabre.dev" },
      pm:       { name: "Alex Park",     email: "pm@collabre.dev" },
      lead:     { name: "Sam Okafor",    email: "lead@collabre.dev" },
      fe1:      { name: "Rin Tanaka",    email: "fe1@collabre.dev" },
      fe2:      { name: "Nora Vidal",    email: "fe2@collabre.dev" },
      be1:      { name: "Ivan Petrov",   email: "be1@collabre.dev" },
      be2:      { name: "Mei Lin",       email: "be2@collabre.dev" },
      designer: { name: "Jules Moreau",  email: "design@collabre.dev" },
      qa:       { name: "Priya Nair",    email: "qa@collabre.dev" },
      devops:   { name: "Tomas Brandt",  email: "devops@collabre.dev" }
    }
  else
    {
      ceo:      { name: "김대표",   email: "ceo@collabre.dev" },
      pm:       { name: "박기획",   email: "pm@collabre.dev" },
      lead:     { name: "이시니어", email: "lead@collabre.dev" },
      fe1:      { name: "정프론트", email: "fe1@collabre.dev" },
      fe2:      { name: "한프론트", email: "fe2@collabre.dev" },
      be1:      { name: "송백엔드", email: "be1@collabre.dev" },
      be2:      { name: "윤백엔드", email: "be2@collabre.dev" },
      designer: { name: "조디자인", email: "design@collabre.dev" },
      qa:       { name: "최테스트", email: "qa@collabre.dev" },
      devops:   { name: "강데옵스", email: "devops@collabre.dev" }
    }
  end

created_users = {}
users.each do |role, attrs|
  u = Collavre::User.find_or_initialize_by(email: attrs[:email])
  u.name = attrs[:name]
  u.password = pw
  u.password_confirmation = pw
  u.email_verified_at = Time.current if u.respond_to?(:email_verified_at=)
  u.save!
  created_users[role] = u
  $stdout.puts "User: #{u.name} (#{u.email})"
end

# AI Agent "Vrex" — real OpenAI-vendor agent pointed at the local fake LLM.
ai = Collavre::User.find_or_initialize_by(email: "ai-agent@collabre.dev")
ai.name = "Vrex"
ai.password = pw
ai.password_confirmation = pw
ai.llm_vendor = "openai"
ai.llm_model = "demo"
ai.llm_api_key = "demo-key"
ai.gateway_url = llm_url
ai.tools = [] if ai.respond_to?(:tools=)
ai.system_prompt = "You are Vrex, an AI teammate at Collabre. Help the team with code reviews, architecture decisions, and documentation."
ai.email_verified_at = Time.current if ai.respond_to?(:email_verified_at=)
ai.save!
created_users[:ai] = ai
$stdout.puts "AI Agent: #{ai.name} -> #{ai.gateway_url} (vendor=#{ai.llm_vendor})"

pm_user = created_users[:pm]

# Force the login user's theme so recordings are deterministic regardless of any
# admin-configured default theme (`body.dark-mode` / `body.light-mode` are
# explicit and do not depend on the OS prefers-color-scheme).
demo_theme = ENV["DEMO_THEME"].to_s.strip.downcase
if %w[light dark].include?(demo_theme) && pm_user.respond_to?(:theme=)
  pm_user.update!(theme: demo_theme)
  $stdout.puts "Login user theme set to: #{demo_theme}"
end

# Collavre picks its UI locale off the user record, NOT off the browser's
# Accept-Language — so Playwright's `locale:` alone leaves the app chrome in
# whatever the seeded default was, and the take is unusable for its audience.
pm_user.update!(locale: locale) if pm_user.respond_to?(:locale=)
$stdout.puts "Login user locale set to: #{locale}"

# Clean existing demo data so re-runs don't stack duplicate creative trees.
# Scope to the exact demo users upserted above instead of a magic id threshold
# (`user_id > 3` assumed exactly three reserved system users), and let failures
# surface rather than swallowing them: a silently half-completed delete would
# leave a stale duplicate tree, and record.mjs's `rowLocator(...).first()` could
# then pick a stale row with no topic/permissions — reproducing the dark-run
# waitStream timeout.
#
# destroy_all (not delete_all) is required: it instantiates each Creative and
# fires the dependent associations. Collavre::Creative includes Permissible,
# which declares `has_many :creative_shares, dependent: :destroy` and
# `has_many :creative_shares_caches, dependent: :delete_all` — so the @Vrex
# :feedback shares (and their permission caches) granted below are torn down by
# the cascade before the creative_shares→creatives RESTRICT FK is evaluated. The
# rest of the dependent chain (topics → comments → comment_snapshots) covers the
# snapshot FK, so destroy_all completes cleanly on the second pass of a
# `--theme light,dark` run.
demo_user_ids = created_users.values.map(&:id)
Collavre::Creative.where(user_id: demo_user_ids).destroy_all

def create_creative(parent:, user:, desc:, progress: 0, data: {}, seq: nil)
  Collavre::Creative.create!(
    parent: parent,
    user_id: user.id,
    description: desc,
    progress: progress,
    data: data,
    sequence: seq
  )
end

if scenario == "launch"
  # ─── The handbook: the context block the video pins at the root ───
  #
  # This must carry REAL, quotable rules. The climax of the video is Vrex citing a
  # rule it was never told — so if the handbook were lorem ipsum, the scripted
  # answer in launch.yml would be a lie the viewer could not check. It is the one
  # thing the recording asserts and the seed must make true.
  #
  # Both language versions therefore have to state the SAME four rules: the
  # scripted answer in launch.yml quotes three of them back, per locale.
  handbook_lines =
    if ko
      [
        "<b>엔지니어링 핸드북</b>",
        "모든 공개 엔드포인트에는 속도 제한을 건다. 기본값은 토큰당 분당 100회.",
        "모든 쓰기 엔드포인트는 Idempotency-Key 헤더를 받고, 재시도해도 안전해야 한다.",
        "API를 바꾸면 마이그레이션 가이드를 같은 PR에 함께 올린다.",
        "CI가 초록이 아니면 머지하지 않는다. 핫픽스도 예외가 아니다."
      ]
    else
      [
        "<b>Engineering Handbook</b>",
        "Every public endpoint is rate-limited. Default: 100 requests/minute per token.",
        "Every write endpoint accepts an Idempotency-Key header and must be safe to retry.",
        "Any API change ships with a migration guide in the same pull request.",
        "No merge without a green CI run. No exceptions, including hotfixes."
      ]
    end

  handbook = create_creative(
    parent: nil, user: created_users[:lead], progress: 1.0, seq: 2,
    desc: html_lines(handbook_lines)
  )

  # ─── The project root: deliberately EMPTY ───
  #
  # The tree is built on camera by importing markdown into this node. Seeding it
  # empty is the point: a pre-populated tree would prove nothing about the import.
  payments = create_creative(
    parent: nil, user: pm_user, progress: 0.0, seq: 1,
    desc: html(ko ? "결제 v2" : "Payments v2")
  )

  # Vrex is shared on the root BEFORE the import runs. Creative::Permissible
  # rebuilds the permission cache on every parent_id change — including on create —
  # so the children the import creates inherit this share without a background
  # worker having to catch up mid-recording.
  [ payments, handbook ].each do |root|
    share = Collavre::CreativeShare.find_or_initialize_by(creative: root, user: ai)
    share.permission = :feedback
    share.shared_by = pm_user if share.respond_to?(:shared_by=)
    share.save!
    Collavre::PermissionCacheJob.new.perform(:rebuild_user_cache_for_subtree, creative_id: root.id, user_id: ai.id)
  end
  $stdout.puts "Granted Vrex :feedback on the project root and the handbook"

  # The handbook is owned by the tech lead, not by the PM who records the video —
  # deliberately. The point being demonstrated is that context someone ELSE wrote,
  # pinned once, reaches your agent. But owning an ancestor does not cascade, so
  # the PM needs an explicit share or the handbook is invisible in their tree and
  # in the link-creative picker the video drives.
  pm_share = Collavre::CreativeShare.find_or_initialize_by(creative: handbook, user: pm_user)
  pm_share.permission = :feedback
  pm_share.shared_by = created_users[:lead] if pm_share.respond_to?(:shared_by=)
  pm_share.save!
  Collavre::PermissionCacheJob.new.perform(:rebuild_user_cache_for_subtree, creative_id: handbook.id, user_id: pm_user.id)
  $stdout.puts "Granted PM :feedback on the lead-owned handbook"

  $stdout.puts "\n=== Demo seed complete (scenario=launch, locale=#{locale}) ==="
  $stdout.puts "Users: #{Collavre::User.count}"
  $stdout.puts "Creatives: #{Collavre::Creative.count} (project root is intentionally empty)"
  exit 0
end

# ─── Project: Collabre v2.0 release ───
v2 = create_creative(parent: nil, user: pm_user, desc: html("콜라브 v2.0 릴리즈"), progress: 0.68, seq: 1)

ms_design = create_creative(parent: v2, user: pm_user, desc: html("디자인 시스템 리뉴얼"), progress: 0.95, seq: 1)
ms_api    = create_creative(parent: v2, user: pm_user, desc: html("API v2 개발"), progress: 0.75, seq: 2)
ms_fe     = create_creative(parent: v2, user: pm_user, desc: html("프론트엔드 리팩토링"), progress: 0.6, seq: 3)
ms_launch = create_creative(parent: v2, user: pm_user, desc: html("런칭 준비"), progress: 0.3, seq: 4)

create_creative(parent: ms_design, user: created_users[:designer], desc: html("컬러 토큰 정의"), progress: 1.0, seq: 1)
create_creative(parent: ms_design, user: created_users[:designer], desc: html("타이포그래피 스케일"), progress: 1.0, seq: 2)
create_creative(parent: ms_design, user: created_users[:designer], desc: html("컴포넌트 라이브러리"), progress: 0.85, seq: 3)

create_creative(parent: ms_api, user: created_users[:lead], desc: html("인증 시스템 마이그레이션"), progress: 1.0, seq: 1)
create_creative(parent: ms_api, user: created_users[:be1], desc: html("GraphQL 엔드포인트"), progress: 0.8, seq: 2)
create_creative(parent: ms_api, user: created_users[:be2], desc: html("성능 최적화 (캐시, 인덱스)"), progress: 0.45, seq: 3)

create_creative(parent: ms_fe, user: created_users[:fe1], desc: html("크리에이티브 트리 뷰 개선"), progress: 0.7, seq: 1)
create_creative(parent: ms_fe, user: created_users[:fe2], desc: html("채팅 UI 리디자인"), progress: 0.55, seq: 2)
create_creative(parent: ms_fe, user: created_users[:fe1], desc: html("접근성(a11y) 개선"), progress: 0.4, seq: 3)

create_creative(parent: ms_launch, user: pm_user, desc: html("베타 테스트 계획"), progress: 0.6, seq: 1)
create_creative(parent: ms_launch, user: created_users[:qa], desc: html("QA 체크리스트"), progress: 0.3, seq: 2)
create_creative(parent: ms_launch, user: created_users[:devops], desc: html("인프라 스케일링"), progress: 0.2, seq: 3)
create_creative(parent: ms_launch, user: pm_user, desc: html("마케팅 랜딩 페이지"), progress: 0.1, seq: 4)

# ─── Project: Technical debt cleanup ───
tech_debt = create_creative(parent: nil, user: created_users[:lead], desc: html("기술 부채 해소"), progress: 0.4, seq: 2)
create_creative(parent: tech_debt, user: created_users[:be1], desc: html("Ruby 3.4 업그레이드"), progress: 1.0, seq: 1)
create_creative(parent: tech_debt, user: created_users[:be2], desc: html("레거시 API 제거"), progress: 0.5, seq: 2)
create_creative(parent: tech_debt, user: created_users[:devops], desc: html("CI/CD 파이프라인 개선"), progress: 0.3, seq: 3)
create_creative(parent: tech_debt, user: created_users[:fe1], desc: html("테스트 커버리지 80% 달성"), progress: 0.2, seq: 4)

# ─── Project: Onboarding guide ───
onboard = create_creative(parent: nil, user: pm_user, desc: html("신규 입사자 온보딩"), progress: 0.85, seq: 3)
create_creative(parent: onboard, user: pm_user, desc: html("개발 환경 셋업 가이드"), progress: 1.0, seq: 1)
create_creative(parent: onboard, user: created_users[:lead], desc: html("코드 리뷰 프로세스"), progress: 1.0, seq: 2)
create_creative(parent: onboard, user: pm_user, desc: html("회사 문화와 원칙"), progress: 0.9, seq: 3)
create_creative(parent: onboard, user: created_users[:designer], desc: html("디자인 시스템 사용법"), progress: 0.5, seq: 4)

ms_api.update!(data: { "context_ids" => [ onboard.id ] })

# ─── Grant Vrex feedback permission so @Vrex mentions actually route ───
# The orchestration Matcher requires the mentioned agent to hold :feedback on
# the creative. Share on the root cascades to the subtree; we rebuild the
# permission cache synchronously so it is in place before recording starts.
[ v2, ms_api ].each do |root|
  share = Collavre::CreativeShare.find_or_initialize_by(creative: root, user: ai)
  share.permission = :feedback
  share.shared_by = pm_user if share.respond_to?(:shared_by=)
  share.save!
  Collavre::PermissionCacheJob.new.perform(:rebuild_user_cache_for_subtree, creative_id: root.id, user_id: ai.id)
end
$stdout.puts "Granted Vrex :feedback on demo roots and rebuilt permission cache"

# ─── Grant the login user (PM) :feedback on every project root ───
# The descendant tasks are deliberately owned by other team members (designer,
# lead, be1…) to show multi-user avatars in the tree. But `children_with_permission`
# only returns children the viewer owns, has a share on, or that are public —
# owning an *ancestor* does NOT cascade. Without an explicit share the PM sees
# 0/3 grandchildren under each milestone, and the hierarchy/context scenes record
# a thin two-level tree instead of the seeded three-level one. The tech_debt root
# is lead-owned, so the PM wouldn't even see it in the root list without this.
# A share on each root cascades to the whole subtree via the rebuilt cache.
[ v2, tech_debt, onboard ].each do |root|
  share = Collavre::CreativeShare.find_or_initialize_by(creative: root, user: pm_user)
  share.permission = :feedback
  share.shared_by = pm_user if share.respond_to?(:shared_by=)
  share.save!
  Collavre::PermissionCacheJob.new.perform(:rebuild_user_cache_for_subtree, creative_id: root.id, user_id: pm_user.id)
end
$stdout.puts "Granted PM :feedback on all project roots and rebuilt permission cache"

# ─── Topics & seeded conversation ───
topic_general = Collavre::Topic.create!(creative: v2, user: pm_user, name: "일반", position: 1)
topic_review  = Collavre::Topic.create!(creative: v2, user: created_users[:lead], name: "코드 리뷰", position: 2)
topic_design  = Collavre::Topic.create!(creative: v2, user: created_users[:designer], name: "디자인 논의", position: 3)

Collavre::Comment.create!(creative: v2, user: pm_user, topic: topic_general,
  content: "v2.0 스프린트 시작합니다! 각 파트 리드분들 진행상황 업데이트 부탁드려요 🚀")
Collavre::Comment.create!(creative: v2, user: created_users[:lead], topic: topic_general,
  content: "API 인증 마이그레이션 완료했습니다. GraphQL 엔드포인트 80% 진행중이에요.")
Collavre::Comment.create!(creative: v2, user: created_users[:fe1], topic: topic_general,
  content: "트리 뷰 개선 70% 완료. 드래그앤드롭 성능 이슈가 좀 있어서 확인 부탁해요.")
Collavre::Comment.create!(creative: v2, user: created_users[:designer], topic: topic_general,
  content: "디자인 시스템 컴포넌트 85% 완료. 나머지는 다크모드 관련 토큰 조정이에요.")

Collavre::Comment.create!(creative: v2, user: created_users[:lead], topic: topic_review,
  content: "PR #245 리뷰 부탁합니다. GraphQL subscription 구현이에요.")
Collavre::Comment.create!(creative: v2, user: created_users[:be1], topic: topic_review,
  content: "N+1 쿼리는 batch loader로 처리했고, authorization check도 추가했습니다.")

Collavre::Comment.create!(creative: v2, user: created_users[:designer], topic: topic_design,
  content: "새 컴포넌트 시안 올립니다. 버튼 스타일 A/B 안 중 어떤 게 나을까요?")
Collavre::Comment.create!(creative: v2, user: pm_user, topic: topic_design,
  content: "A안이 우리 브랜드 톤에 더 맞는 것 같아요. 둥근 모서리가 친근한 느낌을 줘요.")

Collavre::Topic.create!(creative: ms_api, user: created_users[:lead], name: "기술 논의", position: 1).tap do |topic_api|
  Collavre::Comment.create!(creative: ms_api, user: created_users[:lead], topic: topic_api,
    content: "캐시 전략 논의가 필요합니다. Redis vs Memcached, 어떻게 생각하세요?")
end

$stdout.puts "\n=== Demo seed complete ==="
$stdout.puts "Users: #{Collavre::User.count}"
$stdout.puts "Creatives: #{Collavre::Creative.count}"
$stdout.puts "Topics: #{Collavre::Topic.count}"
$stdout.puts "Comments: #{Collavre::Comment.count}"
