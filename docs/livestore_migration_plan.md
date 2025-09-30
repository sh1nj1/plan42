# LiveStore 전환 계획: 단계별 접근법

## 🚀 Phase 1: LiveStore 기반 구조 준비 (2-3주)

### 1.1 Dependencies 설치
```bash
npm install @livestore/livestore @livestore/react
# 또는 사용 중인 프레임워크에 맞게
```

### 1.2 LiveStore 스키마 구현
- [ ] `app/javascript/livestore/schema/` 디렉토리 생성
- [ ] Creative 이벤트, 테이블, 매테리얼라이저 구현
- [ ] 기본 쿼리 정의
- [ ] TypeScript 타입 정의

### 1.3 기존 API 래퍼 생성
```typescript
// app/javascript/livestore/api/creative-api-wrapper.ts
// 기존 Rails API를 LiveStore 이벤트로 변환하는 래퍼
export class CreativeApiWrapper {
  constructor(private store: LiveStore) {}

  async createCreative(data: CreateCreativeData) {
    // 1. 로컬에서 즉시 이벤트 커밋
    const id = generateId();
    await this.store.commit(creativeEvents.creativeCreated({
      id,
      ...data,
    }));
    
    // 2. 백그라운드에서 서버 동기화
    this.syncToServer('create', { id, ...data });
    
    return { id };
  }

  private async syncToServer(action: string, data: any) {
    try {
      // 기존 Rails API 호출
      await fetch('/creatives', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });
    } catch (error) {
      // 오프라인 큐에 저장하거나 재시도 로직
      console.error('Server sync failed:', error);
    }
  }
}
```

## 🔄 Phase 2: 하이브리드 모드 (3-4주)

### 2.1 양방향 동기화 구현
- [ ] 서버→클라이언트: WebSocket 또는 Server-Sent Events
- [ ] 클라이언트→서버: 배치 이벤트 전송
- [ ] 충돌 해결 로직

### 2.2 Rails API 수정
```ruby
# app/controllers/creatives_controller.rb
class CreativesController < ApplicationController
  # 기존 CRUD는 유지하되, 이벤트도 브로드캐스트
  def create
    @creative = Creative.new(creative_params)
    
    if @creative.save
      # LiveStore 이벤트 브로드캐스트
      broadcast_creative_event('creative_created', @creative)
      render json: @creative
    else
      render json: { errors: @creative.errors }, status: 422
    end
  end

  private

  def broadcast_creative_event(event_type, creative)
    # WebSocket 또는 EventSource로 브로드캐스트
    ActionCable.server.broadcast(
      "user_#{current_user.id}_creatives",
      {
        event: event_type,
        data: creative.as_json
      }
    )
  end
end
```

### 2.3 점진적 UI 전환
```typescript
// 컴포넌트별로 점진적 전환
// 1. Creative 리스트부터 시작
// 2. 드래그&드롭
// 3. 편집 모드
// 4. 댓글 시스템
```

## ⚡ Phase 3: 완전 전환 (2-3주)

### 3.1 모든 UI를 LiveStore 기반으로 전환
- [ ] 모든 Creative CRUD 작업
- [ ] 실시간 협업 기능
- [ ] 오프라인 지원

### 3.2 서버 API 간소화
```ruby
# 서버는 이벤트 저장소 역할로 축소
class EventsController < ApplicationController
  def sync
    # 클라이언트로부터 이벤트 배치 수신
    events = params[:events]
    
    events.each do |event|
      # 이벤트 검증 및 저장
      process_event(event)
    end
    
    # 다른 클라이언트들에게 브로드캐스트
    broadcast_events_to_other_clients(events)
    
    render json: { status: 'ok' }
  end

  private

  def process_event(event)
    case event[:type]
    when 'v1.CreativeCreated'
      Creative.create!(event[:data])
    when 'v1.CreativeUpdated'
      Creative.find(event[:data][:id]).update!(event[:data])
    # ... 기타 이벤트 처리
    end
  end
end
```

## 🔧 Phase 4: 최적화 및 안정화 (1-2주)

### 4.1 성능 최적화
- [ ] 쿼리 인덱싱
- [ ] 메모리 사용량 모니터링
- [ ] 배치 동기화 최적화

### 4.2 오류 처리 및 복구
- [ ] 네트워크 오류 처리
- [ ] 데이터 무결성 검증
- [ ] 충돌 해결 UI

## 📊 측정 가능한 목표

### 성능 개선 목표
- [ ] 초기 로딩 시간: 50% 단축
- [ ] UI 반응성: <50ms 지연
- [ ] 오프라인 작업: 100% 지원

### 사용자 경험 개선
- [ ] 즉각적인 UI 반응
- [ ] 실시간 협업
- [ ] 오프라인에서도 완전한 기능

## 🚨 위험 요소 및 대응

### 1. 데이터 일관성 위험
- **대응**: 서버 검증 + 클라이언트 롤백
- **모니터링**: 데이터 무결성 체크

### 2. 복잡성 증가
- **대응**: 단계적 전환 + 충분한 테스트
- **문서화**: 상세한 아키텍처 문서

### 3. 성능 저하 위험
- **대응**: 성능 모니터링 + 프로파일링
- **최적화**: 쿼리 최적화 + 캐싱

## 📋 체크리스트

### Phase 1 완료 조건
- [ ] LiveStore 스키마 구현 완료
- [ ] 기본 CRUD 동작 확인
- [ ] 하나의 컴포넌트에서 동작 검증

### Phase 2 완료 조건
- [ ] 실시간 동기화 작동
- [ ] 오프라인 모드 기본 지원
- [ ] 주요 기능들이 하이브리드 모드에서 작동

### Phase 3 완료 조건
- [ ] 모든 UI가 LiveStore 기반
- [ ] 기존 기능 100% 동등성
- [ ] 성능 목표 달성

### Phase 4 완료 조건
- [ ] 프로덕션 안정성 확보
- [ ] 모니터링 및 알람 설정
- [ ] 사용자 만족도 개선 확인

## 🛠️ 개발 도구 및 유틸리티

### 디버깅 도구
```typescript
// app/javascript/livestore/debug/dev-tools.ts
export const setupDevTools = () => {
  if (process.env.NODE_ENV === 'development') {
    // LiveStore DevTools 설정
    window.livestoreDebug = {
      showEvents: () => store.getEvents(),
      showState: () => store.getState(),
      rollback: (eventId) => store.rollback(eventId),
    };
  }
};
```

### 마이그레이션 도구
```typescript
// scripts/migrate-existing-data.ts
export const migrateExistingCreatives = async () => {
  // 기존 Rails 데이터를 LiveStore 이벤트로 변환
  const creatives = await fetch('/creatives.json').then(r => r.json());
  
  for (const creative of creatives) {
    await store.commit(creativeEvents.creativeCreated({
      id: creative.id.toString(),
      userId: creative.user_id.toString(),
      parentId: creative.parent_id?.toString(),
      description: creative.description,
      progress: creative.progress,
      sequence: creative.sequence,
    }));
  }
};
```
