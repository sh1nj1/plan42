# T4/T5 원본 보존 manifest

- 저장소: sh1nj1/plan42
- 원격 전달 브랜치: preserve/t4-t5-recovery-20260908
- 원본 checkout: /tmp/plan42-worktree3 (feat/dnd-input-registry)
- 원본 SHA: 5b945fdad7498f350c787a6ee11ece8d46d256c5
- bundle 필수 기반 SHA: 5ca92af7c0cf27eecd9e8229ae36630ae43fb910
- 이 브랜치는 복구 자료 전달용입니다. 브랜치 HEAD는 원본 구현 SHA가 아니며, 원본 구현은 bundle에서 정확한 SHA로 복구합니다. T4와 T5가 동일 원본 커밋을 공유합니다.
- 재구현, 원본 삭제, 초기화 없이 기존 자료를 보존했습니다.

## T5 범위와 미완료 가능성

원본 코드에서 확인:
- contexts_controller.js: 드롭된 여러 ID를 컨텍스트 목록에 추가. 기존/상속 컨텍스트 ID 제외 및 Set 중복 제거 후 기존 update_contexts PATCH 1회, 목록 재조회.
- form_controller.js: 드롭된 IDs를 순회하여 채팅 입력에 여러 Creative 링크 삽입.
- T4 registry 전환, preview 변경, 관련 컨트롤러·스타일·템플릿·테스트를 포함한 공통 14개 변경 파일은 changed-files.txt 참조.
- 신규 배치 API는 이 변경에 포함되지 않습니다.

미확인/미완료 가능성:
- **번들 이미지 공용화 완료를 확인하지 못했습니다.** preview 공용 변경만으로 번들 drag-image 공용화 완료로 판단하지 않습니다.
- 실패·부분 성공의 사용자 표시/롤백 및 모든 타겟의 정책·테스트 완전성은 인증하지 않습니다. 컨텍스트 요청 실패는 원본 코드에서 console.error로 처리합니다.
- 과거 세션의 T4/T5 완료 보고는 전체 T5 요구사항 충족을 보증하지 않습니다.
- 원본 커밋 외에 미커밋 T1 의존 파일 envelope.js, hit_test.js, session.js가 과거 테스트 checkout에 존재했습니다. 별도 압축 파일에 보존했으며 커밋만으로 테스트 환경이 완결되었다고 판단하면 안 됩니다.

## 기존 테스트 결과 (재실행하지 않음)

- 2026-09-08 11:52:23 UTC 기록: 42 suites / 770 tests 통과 (comments controllers + lib/dnd).
- 같은 기록: list DnD / presence participant 2 suites / 30 tests 통과.
- 11:49:21 UTC 기록: 3 suites / 36 tests 통과, registry.js / preview.js coverage 네 항목 100%.
- original-test-results.log에 이전 실패도 포함해 보존했습니다. 새 CI/테스트 통과를 주장하지 않습니다.
- 전달 시 git bundle verify 성공, 기반 SHA 확인.

## Mac 복구

기존 checkout을 변경하지 않고 새 디렉터리에 복제합니다:

```bash
git clone --branch preserve/t4-t5-recovery-20260908 https://github.com/sh1nj1/plan42.git plan42-t5-recovery
cd plan42-t5-recovery
base64 -D -i preservation/t4-t5/T4-T5-history.bundle.base64 -o ../T4-T5-history.bundle
base64 -D -i preservation/t4-t5/original-untracked-dependencies.tar.gz.base64 -o ../original-untracked-dependencies.tar.gz
git bundle verify ../T4-T5-history.bundle
git fetch ../T4-T5-history.bundle refs/heads/preserve/t5-original-20260908:refs/heads/recovered/t4-t5-original
git worktree add ../plan42-t5-original recovered/t4-t5-original
git -C ../plan42-t5-original rev-parse HEAD
# 예상: 5b945fdad7498f350c787a6ee11ece8d46d256c5
# 새 복구 worktree에 과거 미커밋 의존 파일을 복원:
tar -xzf ../original-untracked-dependencies.tar.gz -C ../plan42-t5-original
```

T4-T5-original.patch는 원본 단일 커밋의 format-patch입니다. 정확한 SHA와 선행 로컬 이력 보존에는 bundle을 사용하세요.

## SHA-256

아래 값은 base64 파일의 경우 디코딩한 원본 바이트 기준입니다.

- T4-T5-original.patch: `ed3092aaa35ee4eddccfd5951d503f4523c601a2104a241d1dae29ea5023377e`
- T4-T5-history.bundle.base64: `21d7038208f21c89b8c954e089d558824752f66ca3a646af61cace3425ff425a`
- original-untracked-dependencies.tar.gz.base64: `2956dc061f520dc1babe0ec99732140042c82355e8d6fe639b427c5fd075581e`
- original-test-results.log: `8411ff102ec6f60041a659d6334818ad9abb8098177b8ebec486423ab1a02f84`
- changed-files.txt: `93509740db4af5eecb005930e73a61d835b19d9861e14c6305f24d6f2764d79c`
- untracked-sha256.txt: `ef18099ddea88bea9efe8e8d8100333a13fb82f01fe685dcfae47076f4870684`
