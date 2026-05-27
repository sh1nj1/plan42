# CloudFront behavior — /public-assets/*

Collavre 의 외부 공개 첨부(랜딩페이지 자산 등)는 `/public-assets/blobs/:signed_id/*filename`
경로로 서빙된다. `PublicAssetsController` 가 `Cache-Control: public, max-age=31536000, immutable`
을 강제하므로 CloudFront 가 안전하게 캐시할 수 있다.

## 추가해야 할 CloudFront cache behavior

기존 Rails 앞 distribution 에 behavior 한 줄 추가:

- **Path pattern:** `/public-assets/*`
- **Origin:** 기존 Rails origin 그대로
- **Viewer protocol policy:** Redirect HTTP to HTTPS
- **Allowed methods:** GET, HEAD
- **Cache policy:** Managed-CachingOptimized (또는 동등한 long-TTL: min 1d, default 1y, max 1y)
- **Origin request policy:** Managed-CORS-S3Origin (Host 헤더만 forward, 쿠키/Authorization forward 금지)
- **Compress objects automatically:** Yes

## 환경 변수

- `PUBLIC_ASSETS_HOST` (선택) — CloudFront 도메인. 설정하면 MCP tool 응답의 `url` 이
  절대 URL(`https://cdn.example.com/public-assets/...`) 로 나온다. 미설정 시 상대경로.

## 캐시 무효화

`signed_id` 는 blob 고유키 기반으로 결정적이고, attachment 가 재첨부되면 새 signed_id 가
나오므로 별도 invalidation 없이 자연스럽게 교체된다. 의도적으로 무효화하려면 해당
attachment 를 remove → re-attach.

## 권한 모델

`/public-assets/*` 는 **인증 없이 접근 가능**하다. signed_id 가 곧 capability token.
권한 있는 자산이 필요하면 기존 `rails_blob_path` (engine 내부 사용처) 를 그대로 사용 — 그 경로는
CloudFront 캐시 behavior 대상이 아니다.
