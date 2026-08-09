# cli-openai-proxy 요구사항: `type: "config"` 아이템 지원

**보내는 쪽**: Collavre (plan42) / Agent Gateway 통합
**받는 쪽**: cli-openai-proxy
**기준 커밋**: cli-openai-proxy `main` (provision-sync 머지 후), Collavre `feat/agent-gateway-integration`
**상태**: 구현 요청 (v1 범위 확정용 초안)

---

## 1. 배경

Collavre는 AI Agent 워크스페이스마다 프록시에 두 개의 아이템을 프로비저닝한다.

| item | 내용 | 현재 상태 |
| --- | --- | --- |
| `skill: collavre` | Collavre CLI 스킬 (`SKILL.md`, `scripts/collavre`, `references/`) | **동작함** — 브라우저 E2E에서 승인·설치·업그레이드·삭제까지 확인 |
| `config: workspace-config` | 워크스페이스별 `config.json` (Collavre base URL + callback token) | **미지원** — 프록시가 `unsupported`로 보고 |

`skill: collavre`만 설치되면 CLI 바이너리는 있지만 **어느 Collavre 인스턴스에 어떤 자격증명으로 붙을지를 모른다**. `scripts/collavre`는 `~/.config/collavre/config.json`에서 `{ url, token }`을 읽는데 (`skills/collavre/scripts/collavre:11-16`), 이 파일을 워크스페이스별로 배치하는 유일한 채널이 `type: "config"`다. 즉 config 타입이 없으면 프로비저닝 기능 전체가 반쪽이다.

프록시의 기존 설계 원칙(**매니페스트는 경로를 고르지 않는다 / 설치는 파일 배치일 뿐 / 아무것도 실행하지 않는다**)은 그대로 유지한 채, 타입 하나를 추가하는 범위를 요청한다.

---

## 2. Collavre가 실제로 내려보내는 것 (계약 확정치)

매니페스트 (`GET /agents/:agent_id/workspaces/:token/provision.json`, 비인증 공개 + rate limit 60/min):

```json
{
  "schema": "agent-provisioning/v1",
  "items": [
    { "type": "skill",  "name": "collavre", "url": "https://<app-host>/agents/provision/skill/<sha256>.tar.gz",            "sha256": "…" },
    { "type": "config", "name": "collavre", "url": "https://<app-host>/agents/provision/config/<agent>/<token>/<sha256>.tar.gz", "sha256": "…" }
  ]
}
```

config 아티팩트(`.tar.gz`) 내용은 **파일 하나뿐**이다.

```
config.json   (mode 0600, uid/gid 0, mtime 0, ~150 bytes)
```

```json
{
  "url": "https://collavre.example.com",
  "token": "<Doorkeeper access token — scope: public, 무기한, 회전 가능>"
}
```

- tar는 deterministic(엔트리 정렬, mtime 0, uid/gid 0)이라 **내용이 같으면 sha256이 같다**. 토큰 회전 시에만 sha256이 바뀐다.
- 아티팩트는 매니페스트와 **같은 호스트**에서 서빙된다(기본 host policy 충족, `PROVISION_ALLOWLIST` 불필요).
- 아티팩트 URL은 sha256을 경로에 포함하고, 콜라브는 **현재 sha와 불일치하면 404**를 반환한다(= URL은 해당 매니페스트 리비전에서만 유효).
- config 아티팩트 응답 헤더는 `Cache-Control: private, no-store` (skill 아티팩트는 immutable 캐시).

---

## 3. 요구사항

### R1 (MUST) `type: "config"`를 지원 타입으로 추가

`SUPPORTED_PROVISION_TYPES`(`src/provision/types.ts:47`)에 `config` 추가. 상태뷰는 `type: "config"`를 그대로 반환한다 — Collavre UI가 `skill:collavre` / `config:collavre` 2행을 타입 기준으로 렌더링한다.

**Acceptance**: 위 §2 매니페스트로 sync 하면 config 아이템이 `unsupported`가 아니라 `pending_approval`(기본) 또는 `installed`(auto)로 보고된다.

### R2 (MUST) 설치 경로 = `{CONFIG_ROOT}/{name}`, 매니페스트는 경로를 고르지 않는다

- `CONFIG_ROOT` 기본값 **`$HOME/.config`**, `PROVISION_CONFIG_DIR`로 override.
- `name`은 skill과 동일한 정규식(`[a-z0-9][a-z0-9_-]{0,63}`)의 **단일 디렉터리 세그먼트**. path-policy 재사용.
- 결과: `config: collavre` → `~/.config/collavre/config.json`.

**`XDG_CONFIG_HOME`은 참조하지 않기를 요청한다.** Collavre CLI가 `os.homedir()/.config` 고정이라(`skills/collavre/scripts/collavre:11`) 프록시가 XDG를 존중하면 두 경로가 갈린다. 양쪽 다 XDG를 존중하는 쪽으로 가려면 알려달라 — CLI를 먼저 고치겠다.

> **참고 — Collavre 측 변경 사항**: 현재 구현은 item name이 `workspace-config`다. 이 규칙이 확정되면 `collavre`로 바꿔서 `~/.config/collavre/`가 되게 하겠다. (type이 키에 포함되므로 skill의 `collavre`와 이름이 겹쳐도 충돌 없음 — 확인 요청.)

**Acceptance**: 설치 후 `~/.config/collavre/config.json`이 존재하고 내용이 아티팩트와 동일. `PROVISION_CONFIG_DIR`을 바꾸면 그 아래에 설치된다. `name`에 `../`, `/`, 대문자가 들어오면 `invalid_item`.

### R3 (MUST) 워커 스코프가 선결 조건 — 게이트웨이 전역 설치는 안 된다

config 아이템은 **워크스페이스 고유 자격증명**을 담는다. 지금처럼 `/v1/provision/*`가 워커 포워딩에서 제외되고(`src/server/index.ts:201-207`) 설치 경로가 게이트웨이 HOME 기준이면:

- 사용자 A의 callback token이 게이트웨이 HOME에 설치되고,
- per-user 워커에서 도는 CLI는 그 파일을 보지 못하며(기능 실패),
- 게이트웨이 사용자로 도는 다른 엔진은 **남의 워크스페이스 토큰을 보게 된다**(보안 실패).

따라서 **②(provisioning 워커 스코프화)가 config 타입보다 먼저 또는 함께 배포되어야 한다.** config 타입만 단독 배포하면 안 된다.

구체적으로:
- `/v1/provision/*`를 `/v1/auth/*`처럼 신원 기준 워커 포워딩(`scoped`)으로.
- `PROVISION_CONFIG_DIR` / `PROVISION_SKILLS_DIR` / 락파일(`PROVISION_STATE_DIR`)이 모두 **워커 HOME** 기준.
- 워커에서 성사된 auth 세션의 `provisioning_url`이 **게이트웨이 전역 매니페스트를 대체하지 않고 워커-로컬로 등록**되어야 한다(`src/provision/sync.ts:755-763` 현재 동작이 전역 교체).

**Acceptance**: 서로 다른 신원 헤더로 각각 로그인한 워크스페이스 두 개가 각자의 `config.json`을 자기 HOME에 갖고, 상대의 토큰이 보이지 않는다.

### R4 (MUST) 파일 권한 — 디렉터리 0700, 파일 0600

config는 credential이므로 skill의 일반 파일 권한을 그대로 쓰면 안 된다. 설치된 `config.json`은 **소유자 전용 0600**, 디렉터리는 **0700**이어야 한다. (현재 installer가 staging에 `mode: 0o700` / `0o600`을 쓰는 것으로 보이는데, config 경로에서 이 값이 최종 결과로 보장되는지 테스트로 잠가주기를 요청한다.)

**Acceptance**: `stat` 결과가 `-rw------- config.json`, `drwx------ collavre/`. 아카이브가 더 느슨한 mode를 담고 있어도 0600으로 강제된다.

### R5 (MUST) 시크릿 비노출 — 회귀 테스트로 고정

확인한 바로는 현재 상태뷰가 아카이브 아이템에 `sha256`만 싣고 URL을 싣지 않으며(`itemSourceView`, `src/provision/sync.ts:98-110`), 에러 문자열에도 URL이나 응답 body가 들어가지 않는다(`installer.ts:98` 등). config 아티팩트 URL에는 `manifest_token`이, 파일 내용에는 callback token이 들어 있으므로 **이 성질을 명시적 테스트로 잠가달라**:

- `GET /v1/provision` 응답 JSON 어디에도 아티팩트 URL / 파일 내용이 없다.
- `last_error` / `error` / 서버 로그에 아티팩트 URL이나 body가 없다(HTTP 상태 코드까지만).

### R6 (MUST) 캐시 금지 + 매 sync 재fetch

- config 아티팩트 응답은 `Cache-Control: private, no-store`다. 프록시는 아티팩트 바이트를 스테이징 외부에 남기지 않는다.
- 아티팩트 URL은 매니페스트 리비전에 종속(§2)이므로, **sync마다 매니페스트를 먼저 재fetch하고 그 매니페스트의 URL만 사용**해야 한다. 이전 sync의 URL을 재사용하면 토큰 회전 후 404가 난다.

**Acceptance**: 토큰 회전 → 다음 sync에서 새 sha로 정상 재설치. 재시도 경로에서도 stale URL 재사용이 없다.

### R7 (MUST) content-hash idempotency 유지 → 토큰 회전 = 자동 재설치

기존 원칙 그대로. 내용이 같으면 재설치하지 않고, sha256이 바뀌면(=토큰 회전, base URL 변경) **추가 승인 없이** 업그레이드된다(승인은 이름 단위).

**Acceptance**: 내용 무변경 sync는 mtime을 바꾸지 않는다. Collavre에서 `rotate_tokens!` 후 sync 하면 `config.json`의 token이 새 값으로 바뀐다.

### R8 (MUST) 원자적 교체

토큰 회전 중 CLI가 부분 파일을 읽으면 안 된다. skill과 동일하게 stage → atomic rename. 실패 시 **직전 config가 그대로 유지**된다(빈 디렉터리나 절반 쓴 파일 금지).

**Acceptance**: 교체 도중 어느 시점에 읽어도 `config.json`은 항상 유효한 JSON(구버전 또는 신버전).

### R9 (MUST) 제거 시멘틱 — 사용자 파일 보존

매니페스트에서 빠지거나 `DELETE /v1/provision/items/config/collavre` 호출 시, **락파일이 기록한 파일만** 삭제하고 디렉터리는 **비어 있을 때만** 제거한다. 사용자가 `~/.config/collavre/`에 넣어둔 다른 파일은 남는다.

### R10 (SHOULD) untracked 디렉터리 충돌 — config는 파일 단위 소유권으로

skill의 "Refusing to replace untracked directory"를 config에 그대로 적용하면 **실전에서 거의 항상 실패한다**. `~/.config/collavre/`는 사용자가 CLI를 한 번이라도 수동 실행하면 `saveConfig()`가 만들어 두기 때문이다(`skills/collavre/scripts/collavre:27-30`).

요청하는 동작:
- 디렉터리가 이미 존재하는 것만으로는 실패하지 않는다(디렉터리를 채택하되, 락파일에 "디렉터리는 우리 소유가 아님"으로 기록 → R9에서 디렉터리를 지우지 않음).
- 아카이브가 덮어쓰려는 **파일**이 untracked면 실패한다(`Refusing to replace untracked file "config.json"`).
- 그 실패를 푸는 관리자 수단을 제공한다: `POST /v1/provision/items/config/collavre/approve`에 `{"adopt": true}`(또는 별도 엔드포인트) — 수동 config를 프록시 관리로 인계.

대안(프록시 팀 판단): 파일 단위 소유권이 부담이면 "실패 + 명확한 에러 + adopt 플래그"만이라도 필수. **아무 우회 수단 없는 fail-closed는 v1에서 곤란하다.**

### R11 (SHOULD) TOFU 규칙은 skill과 동일

첫 `(config, collavre)`는 `pending_approval`, 승인 후 업그레이드는 자동, `DELETE`는 승인 회수. `PROVISION_AUTOAPPLY=auto`면 즉시 설치. Collavre UI가 이 상태 기계를 이미 그대로 표시한다.

### R12 (MUST) 검증 규칙 재사용 / (판단) 텍스트 스캔은 선택

크기(파일 1MiB, 총 10MiB, 압축 확장 상한), traversal·심볼릭/하드링크·비정규 파일·바이너리 거부, **설치 시 실행 없음** — skill과 동일하게 적용.

단 **pipe-download-into-shell 텍스트 스캔**(`installer.ts:82`)은 "스킬은 프롬프트에 로드된다"는 전제에서 나온 규칙이라 config에는 근거가 약하다. 적용해도 우리 payload는 걸리지 않으니 프록시 팀 판단에 맡긴다(적용 유지 = 무해, 제외 = 의미상 정확).

---

## 4. 이번 배포에서 함께 봐줬으면 하는 것 (별건, E2E에서 발견)

**DELETE 직후 상태 표기가 문서와 다르다.** `docs/provisioning.md`는 "매니페스트에 아직 있으면 `pending_approval`로 돌아온다"고 하는데, 실제로는 DELETE 응답의 상태 목록에서 항목이 **사라진다**(다음 sync에서야 `pending_approval`로 복귀). Collavre UI는 그 사이를 `not_synced`로 표시할 수밖에 없다. 문서를 실제 동작에 맞추든, 동작을 문서에 맞추든 한쪽으로 정리해 주면 UI를 거기에 맞추겠다.

---

## 5. 수용 시나리오 (양쪽 합동 E2E)

1. `PROVISION_SYNC=1`, 워커 모드 프록시에 Collavre가 워크스페이스 A 신원으로 로그인 + `provisioning_url` 전달.
2. `GET /v1/provision` → `skill:collavre`, `config:collavre` 모두 `pending_approval`.
3. 둘 다 approve → `installed`. 워커 A HOME에 `~/.claude/skills/collavre/`와 `~/.config/collavre/config.json`(0600) 존재.
4. 워커 A에서 `collavre` CLI 실행 → config의 url/token으로 Collavre API 호출 성공.
5. 워크스페이스 B로 같은 절차 → B의 HOME에 **B의 토큰만** 존재, A 것 안 보임.
6. Collavre에서 토큰 회전 → sync → 추가 승인 없이 `config.json` 갱신, CLI 재실행 성공.
7. `~/.config/collavre/notes.txt`를 손으로 만들어 둔 뒤 `DELETE .../config/collavre` → `config.json`만 삭제, `notes.txt`와 디렉터리 유지.
8. 매니페스트에서 config 아이템 제거 → 다음 sync에서 `removed`.

---

## 6. 열린 질문 (프록시 팀 회신 요청)

1. **경로 규칙**: `{CONFIG_ROOT}/{name}` + `PROVISION_CONFIG_DIR`, `XDG_CONFIG_HOME` 무시 — 동의하나? (동의 시 Collavre가 item name을 `collavre`로 변경)
2. **동일 name, 다른 type** (`skill:collavre` + `config:collavre`)이 락파일/승인 키에서 안전하게 분리되나?
3. **R10**을 파일 단위 소유권으로 갈지, "실패 + adopt 플래그"로 갈지.
4. **배포 순서**: ②(워커 스코프화)와 config 타입을 한 릴리스로 묶을 수 있나? 분리 배포가 필요하면 config 타입은 워커 모드에서만 활성화되도록 게이트를 걸어달라.
5. R12의 텍스트 스캔 적용 여부.

---

## 7. Collavre 측 준비 상태

- 매니페스트/아티팩트 엔드포인트, deterministic tar, sha256 검증, 토큰 회전, 상태/승인 UI **구현 완료** (`feat/agent-gateway-integration`).
- 프록시가 config를 모르는 현재도 `unsupported`로 표시만 되고 skill 설치는 정상 진행됨을 E2E로 확인 — **점진 배포에 문제 없음**.
- 남은 Collavre 측 작업은 R2 확정 시 item name 변경 하나뿐.
