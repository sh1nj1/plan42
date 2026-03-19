# Demo seed data: 10-person software company using Collavre
# Run: RAILS_ENV=development bin/rails runner db/demo_seed.rb

def html(text)
  "<div><p class=\"lexical-paragraph\"><span style=\"white-space:pre-wrap;\">#{text}</span></p></div>"
end

# === Users (10 people + 1 AI agent) ===
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
  devops:   { name: "강데옵스", email: "devops@collabre.dev" },
}

created_users = {}
users.each do |role, attrs|
  u = Collavre::User.find_or_initialize_by(email: attrs[:email])
  u.name = attrs[:name]
  u.password = pw
  u.password_confirmation = pw
  u.save!
  created_users[role] = u
  $stdout.puts "User: #{u.name} (#{u.email})"
end

# AI Agent
ai = Collavre::User.find_or_initialize_by(email: "ai-agent@collabre.dev")
ai.name = "Vrex"
ai.password = pw
ai.password_confirmation = pw
ai.agent_conf = { "provider" => "anthropic", "model" => "claude-sonnet-4-20250514" }
ai.system_prompt = "You are Vrex, an AI teammate at Collabre. Help the team with code reviews, architecture decisions, and documentation."
ai.save!
created_users[:ai] = ai
$stdout.puts "AI Agent: #{ai.name}"

pm_user = created_users[:pm]

# === Root Creatives (Projects) ===
# Clean existing demo data
Collavre::Creative.where("user_id > 3").destroy_all rescue nil

def create_creative(parent:, user:, desc:, progress: 0, data: {}, seq: nil)
  c = Collavre::Creative.new(
    parent: parent,
    user_id: user.id,
    description: desc,
    progress: progress,
    data: data,
    sequence: seq
  )
  c.save!
  c
end

# ─── Project: 콜라브 v2.0 릴리즈 ───
v2 = create_creative(parent: nil, user: pm_user, desc: html("콜라브 v2.0 릴리즈"), progress: 0.68, seq: 1)

# L2: 마일스톤들
ms_design = create_creative(parent: v2, user: pm_user, desc: html("디자인 시스템 리뉴얼"), progress: 0.95, seq: 1)
ms_api    = create_creative(parent: v2, user: pm_user, desc: html("API v2 개발"), progress: 0.75, seq: 2)
ms_fe     = create_creative(parent: v2, user: pm_user, desc: html("프론트엔드 리팩토링"), progress: 0.6, seq: 3)
ms_launch = create_creative(parent: v2, user: pm_user, desc: html("런칭 준비"), progress: 0.3, seq: 4)

# L3: 디자인 시스템 하위
create_creative(parent: ms_design, user: created_users[:designer], desc: html("컬러 토큰 정의"), progress: 1.0, seq: 1)
create_creative(parent: ms_design, user: created_users[:designer], desc: html("타이포그래피 스케일"), progress: 1.0, seq: 2)
create_creative(parent: ms_design, user: created_users[:designer], desc: html("컴포넌트 라이브러리"), progress: 0.85, seq: 3)

# L3: API v2 하위
api_auth = create_creative(parent: ms_api, user: created_users[:lead], desc: html("인증 시스템 마이그레이션"), progress: 1.0, seq: 1)
api_gql  = create_creative(parent: ms_api, user: created_users[:be1], desc: html("GraphQL 엔드포인트"), progress: 0.8, seq: 2)
api_perf = create_creative(parent: ms_api, user: created_users[:be2], desc: html("성능 최적화 (캐시, 인덱스)"), progress: 0.45, seq: 3)

# L3: 프론트엔드 하위
fe_tree = create_creative(parent: ms_fe, user: created_users[:fe1], desc: html("크리에이티브 트리 뷰 개선"), progress: 0.7, seq: 1)
fe_chat = create_creative(parent: ms_fe, user: created_users[:fe2], desc: html("채팅 UI 리디자인"), progress: 0.55, seq: 2)
fe_a11y = create_creative(parent: ms_fe, user: created_users[:fe1], desc: html("접근성(a11y) 개선"), progress: 0.4, seq: 3)

# L3: 런칭 준비 하위
create_creative(parent: ms_launch, user: pm_user, desc: html("베타 테스트 계획"), progress: 0.6, seq: 1)
create_creative(parent: ms_launch, user: created_users[:qa], desc: html("QA 체크리스트"), progress: 0.3, seq: 2)
create_creative(parent: ms_launch, user: created_users[:devops], desc: html("인프라 스케일링"), progress: 0.2, seq: 3)
create_creative(parent: ms_launch, user: pm_user, desc: html("마케팅 랜딩 페이지"), progress: 0.1, seq: 4)

# ─── Project: 기술 부채 해소 ───
tech_debt = create_creative(parent: nil, user: created_users[:lead], desc: html("기술 부채 해소"), progress: 0.4, seq: 2)
create_creative(parent: tech_debt, user: created_users[:be1], desc: html("Ruby 3.4 업그레이드"), progress: 1.0, seq: 1)
create_creative(parent: tech_debt, user: created_users[:be2], desc: html("레거시 API 제거"), progress: 0.5, seq: 2)
create_creative(parent: tech_debt, user: created_users[:devops], desc: html("CI/CD 파이프라인 개선"), progress: 0.3, seq: 3)
create_creative(parent: tech_debt, user: created_users[:fe1], desc: html("테스트 커버리지 80% 달성"), progress: 0.2, seq: 4)

# ─── Project: 온보딩 가이드 ───
onboard = create_creative(parent: nil, user: pm_user, desc: html("신규 입사자 온보딩"), progress: 0.85, seq: 3)
create_creative(parent: onboard, user: pm_user, desc: html("개발 환경 셋업 가이드"), progress: 1.0, seq: 1)
create_creative(parent: onboard, user: created_users[:lead], desc: html("코드 리뷰 프로세스"), progress: 1.0, seq: 2)
create_creative(parent: onboard, user: pm_user, desc: html("회사 문화와 원칙"), progress: 0.9, seq: 3)
create_creative(parent: onboard, user: created_users[:designer], desc: html("디자인 시스템 사용법"), progress: 0.5, seq: 4)

# ─── Context: API v2에 온보딩 가이드를 컨텍스트로 연결 ───
ms_api.update!(data: { "context_ids" => [onboard.id] })

# ─── Topics & Comments (채팅) ───
# v2 프로젝트에 토픽 생성
topic_general = Collavre::Topic.create!(creative: v2, user: pm_user, name: "일반", position: 1)
topic_review  = Collavre::Topic.create!(creative: v2, user: created_users[:lead], name: "코드 리뷰", position: 2)
topic_design  = Collavre::Topic.create!(creative: v2, user: created_users[:designer], name: "디자인 논의", position: 3)

# 일반 토픽 대화
Collavre::Comment.create!(creative: v2, user: pm_user, topic: topic_general,
  content: "v2.0 스프린트 시작합니다! 각 파트 리드분들 진행상황 업데이트 부탁드려요 🚀")
Collavre::Comment.create!(creative: v2, user: created_users[:lead], topic: topic_general,
  content: "API 인증 마이그레이션 완료했습니다. GraphQL 엔드포인트 80% 진행중이에요.")
Collavre::Comment.create!(creative: v2, user: created_users[:fe1], topic: topic_general,
  content: "트리 뷰 개선 70% 완료. 드래그앤드롭 성능 이슈가 좀 있어서 @Vrex 의견 부탁해요.")
Collavre::Comment.create!(creative: v2, user: ai, topic: topic_general,
  content: "드래그앤드롭 성능 이슈는 requestAnimationFrame으로 throttle하고, 가상 스크롤링을 적용하면 대량 노드에서도 60fps 유지가 가능합니다. 코드 예시를 공유할까요?")
Collavre::Comment.create!(creative: v2, user: created_users[:fe1], topic: topic_general,
  content: "오 좋아요! 코드 예시 부탁드립니다 👍")
Collavre::Comment.create!(creative: v2, user: created_users[:designer], topic: topic_general,
  content: "디자인 시스템 컴포넌트 85% 완료. 나머지는 다크모드 관련 토큰 조정이에요.")

# 코드 리뷰 토픽
Collavre::Comment.create!(creative: v2, user: created_users[:lead], topic: topic_review,
  content: "PR #245 리뷰 부탁합니다. GraphQL subscription 구현이에요.")
Collavre::Comment.create!(creative: v2, user: ai, topic: topic_review,
  content: "PR #245 분석 완료.\n\n✅ 장점: N+1 쿼리 방지를 위한 batch loader 적용이 잘 되어있습니다.\n⚠️ 개선점: subscription resolver에서 authorization check가 빠져있어요. `authorize!` 콜을 추가하세요.\n📝 컨벤션: `resolve` 메서드가 30줄이 넘어가서 private 메서드로 분리하면 좋겠습니다.")
Collavre::Comment.create!(creative: v2, user: created_users[:be1], topic: topic_review,
  content: "Vrex 의견 반영해서 수정했습니다. 감사합니다! 🙏")

# 디자인 논의 토픽
Collavre::Comment.create!(creative: v2, user: created_users[:designer], topic: topic_design,
  content: "새 컴포넌트 시안 올립니다. 버튼 스타일 A/B 안 중 어떤 게 나을까요?")
Collavre::Comment.create!(creative: v2, user: pm_user, topic: topic_design,
  content: "A안이 우리 브랜드 톤에 더 맞는 것 같아요. 둥근 모서리가 친근한 느낌을 줘요.")

# API 크리에이티브에도 대화
topic_api = Collavre::Topic.create!(creative: ms_api, user: created_users[:lead], name: "기술 논의", position: 1)
Collavre::Comment.create!(creative: ms_api, user: created_users[:lead], topic: topic_api,
  content: "캐시 전략 논의가 필요합니다. Redis vs Memcached, 어떻게 생각하세요?")
Collavre::Comment.create!(creative: ms_api, user: ai, topic: topic_api,
  content: "현재 아키텍처 기준으로 보면:\n\n**Redis** 추천 이유:\n1. 이미 ActionCable에서 Redis를 사용중\n2. 데이터 구조가 다양 (sorted set으로 랭킹 등)\n3. persistence 옵션 (AOF)\n\nMemcached는 단순 key-value 캐시에 적합하지만, 현재 요구사항에는 Redis가 더 적합합니다.")

$stdout.puts "\n=== Demo seed complete ==="
$stdout.puts "Users: #{Collavre::User.count}"
$stdout.puts "Creatives: #{Collavre::Creative.count}"
$stdout.puts "Topics: #{Collavre::Topic.count}"
$stdout.puts "Comments: #{Collavre::Comment.count}"
