# Demo seed for the demo-video skill.
# Run: bin/rails runner skills/demo-video/lib/seed.rb
#
# Differs from db/demo_seed.rb in one critical way: the AI teammate "Vrex" is
# configured as a real OpenAI-vendor agent pointed at the local fake LLM server
# (DEMO_LLM_URL). A genuine `@Vrex:` mention then drives the real Collavre
# streaming pipeline against scripted responses — no rails-runner insert trick.
#
# Env:
#   DEMO_LLM_URL  OpenAI-compatible base url for Vrex (default http://127.0.0.1:8730/v1)

llm_url = ENV.fetch("DEMO_LLM_URL", "http://127.0.0.1:8730/v1")

def html(text)
  "<div><p class=\"lexical-paragraph\"><span style=\"white-space:pre-wrap;\">#{text}</span></p></div>"
end

pw = "demo1234"

users = {
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

# Clean existing demo data (everything except the reserved system/admin users).
Collavre::Creative.where("user_id > 3").destroy_all rescue nil

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
