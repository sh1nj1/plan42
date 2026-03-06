# S3 File Storage Setup Guide

Collavre는 파일 업로드(이미지, 아바타 등)를 **로컬 디스크** 또는 **AWS S3**에 저장할 수 있습니다.
기본값은 **로컬 디스크**이며, S3 환경변수를 설정하면 자동으로 S3 스토리지로 전환됩니다.

## 스토리지 전환 방식

`AWS_S3_ACCESS_KEY_ID` 환경변수의 존재 여부로 자동 결정됩니다:

| `AWS_S3_ACCESS_KEY_ID` | 스토리지 | 설명 |
|------------------------|----------|------|
| **비어 있음 (기본)** | 로컬 디스크 | 서버의 `storage/` 디렉토리에 저장 |
| **값이 있음** | AWS S3 | S3 버킷에 암호화(AES-256) 저장 |

> 별도의 코드 변경 없이 환경변수만으로 전환 가능합니다.

---

## 로컬 디스크 모드 (기본)

환경변수를 설정하지 않으면 자동으로 로컬 디스크에 저장됩니다.
추가 설정이 필요 없습니다.

⚠️ **주의**: 로컬 모드에서는 서버 디스크 용량에 제한되며, 서버 이전 시 파일을 직접 복사해야 합니다.

---

## S3 모드 설정

### 1. 필요한 환경변수

| 환경변수 | 필수 | 설명 | 예시 |
|----------|------|------|------|
| `AWS_S3_ACCESS_KEY_ID` | ✅ | S3 전용 IAM Access Key ID | `AKIA3C7HN7GC...` |
| `AWS_S3_SECRET_ACCESS_KEY` | ✅ | S3 전용 IAM Secret Access Key | `wJalrXUtnFEM...` |
| `AWS_S3_BUCKET` | ✅ | S3 버킷 이름 | `collavre-uploads-production` |
| `AWS_REGION` | ❌ | AWS 리전 (기본값: `ap-northeast-2`) | `us-east-1` |

### 2. 자동 셋업 스크립트

AWS CLI가 설치되어 있다면, 버킷 생성부터 IAM 키 발급까지 자동으로 처리하는 스크립트를 제공합니다:

```bash
ruby bin/setup_s3.rb [환경] [aws_profile]

# 예시
ruby bin/setup_s3.rb production default
ruby bin/setup_s3.rb production my-aws-profile
```

이 스크립트가 자동으로 수행하는 작업:
1. S3 버킷 생성 (`collavre-uploads-{환경}`)
2. Public Access 전면 차단
3. 기본 암호화 (AES-256) 활성화
4. IAM 사용자 생성 (해당 버킷만 접근 가능한 최소 권한)
5. Access Key 발급
6. `.env.s3` 파일 생성

스크립트 실행 후 `.env.s3` 파일의 내용을 `.env.production`에 복사하세요.

### 3. 수동 설정 (AWS CLI 없는 경우)

#### 3-1. S3 버킷 생성 (AWS 콘솔)

1. [AWS S3 콘솔](https://s3.console.aws.amazon.com/) 접속
2. **버킷 만들기** 클릭
3. 설정:
   - 버킷 이름: `collavre-uploads-production` (원하는 이름)
   - 리전: 서버와 가까운 리전 선택
   - **기본 암호화**: Amazon S3 관리형 키(SSE-S3) — **AES-256** 활성화
   - **퍼블릭 액세스 차단**: **모든 퍼블릭 액세스 차단** ✅ (반드시 체크)

#### 3-2. IAM 사용자 생성 (AWS 콘솔)

1. [AWS IAM 콘솔](https://console.aws.amazon.com/iam/) 접속
2. **사용자** → **사용자 추가**
3. 사용자 이름: `s3-collavre-production`
4. **직접 정책 연결** → **인라인 정책 생성**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3BucketAccess",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::collavre-uploads-production",
        "arn:aws:s3:::collavre-uploads-production/*"
      ]
    }
  ]
}
```

> ⚠️ `collavre-uploads-production` 부분을 실제 버킷 이름으로 변경하세요.

5. **액세스 키 만들기** → Access Key ID와 Secret Access Key 복사

#### 3-3. 환경변수 설정

`.env.production` 파일에 추가:

```bash
# === S3 File Storage ===
AWS_S3_ACCESS_KEY_ID=AKIA3C7HN7GC...
AWS_S3_SECRET_ACCESS_KEY=wJalrXUtnFEM...
AWS_S3_BUCKET=collavre-uploads-production
# AWS_REGION=ap-northeast-2  # 기본값: ap-northeast-2, 다른 리전 사용 시 설정
```

---

## Kamal 배포 환경

Kamal을 사용하는 경우, 환경변수가 컨테이너까지 전달되려면 세 곳에 설정해야 합니다:

### 1. `.env.production` (실제 값)
```bash
AWS_S3_ACCESS_KEY_ID=AKIA...
AWS_S3_SECRET_ACCESS_KEY=...
AWS_S3_BUCKET=collavre-uploads-production
```

### 2. `.kamal/secrets` (환경변수 참조)
```bash
AWS_S3_ACCESS_KEY_ID=${AWS_S3_ACCESS_KEY_ID}
AWS_S3_SECRET_ACCESS_KEY=${AWS_S3_SECRET_ACCESS_KEY}
AWS_S3_BUCKET=${AWS_S3_BUCKET}
```

### 3. `config/deploy.yml` (`env.secret` 목록)
```yaml
env:
  secret:
    - AWS_S3_ACCESS_KEY_ID
    - AWS_S3_SECRET_ACCESS_KEY
    - AWS_S3_BUCKET
```

> 이 세 곳은 이미 코드에 포함되어 있으므로, `.env.production`에 실제 값만 입력하면 됩니다.

---

## 기존 파일 마이그레이션

로컬 디스크에 저장된 기존 파일을 S3로 마이그레이션하는 Rake 태스크가 포함되어 있습니다.

### 사전 조건
- S3 환경변수 설정 완료
- S3 버킷 생성 완료

### 실행 방법

```bash
# 로컬 개발 환경
bin/rails storage:migrate_to_s3

# Kamal 운영서버
./kamal.sh app exec "bin/rails storage:migrate_to_s3"
```

### 마이그레이션 동작
1. `service_name`이 `local`인 모든 파일을 조회
2. 각 파일의 소유자를 판별하여 사용자별 폴더(`users/{user_id}/`)에 재배치
3. S3에 업로드 후 DB의 `key`와 `service_name`을 업데이트
4. 실패한 파일은 `service_name`이 `local`로 유지되어 재실행 시 재시도 가능

### S3 폴더 구조
```
collavre-uploads-production/
├── users/
│   ├── 42/abc123...   (user 42의 파일)
│   └── 87/def456...   (user 87의 파일)
└── unscoped/
    └── ghi789...      (소유자 불명 파일)
```

> ⚠️ 운영서버에서는 **점검 시간에 실행**하는 것을 권장합니다 (파일 I/O + 네트워크 부하).

---

## 보안 참고사항

- **암호화**: S3에 저장되는 모든 파일은 AES-256 (SSE-S3)으로 자동 암호화
- **접근 제어**: S3 버킷은 Public Access가 완전 차단되며, 앱을 통해서만 접근 가능
- **IAM 최소 권한**: setup 스크립트로 생성된 IAM 사용자는 해당 버킷에만 접근 가능
- **URL 방식**: Rails Active Storage의 redirect 방식 사용 — 사용자에게 직접 S3 URL이 노출되지 않음

---

## 트러블슈팅

### S3 연결 실패
```
Aws::S3::Errors::InvalidAccessKeyId
```
→ `AWS_S3_ACCESS_KEY_ID` 값 확인. IAM 콘솔에서 키가 활성 상태인지 확인.

### 버킷 접근 거부
```
Aws::S3::Errors::AccessDenied
```
→ IAM 사용자의 정책에 해당 버킷이 포함되어 있는지 확인. `AWS_S3_BUCKET` 값이 정확한지 확인.

### 로컬 모드로 동작하는 경우
→ `AWS_S3_ACCESS_KEY_ID` 환경변수가 설정되어 있는지 확인. 비어있으면 자동으로 로컬 모드.

### 마이그레이션 중 파일 누락
```
Blob 123 (image.png): local file missing, skipped
```
→ 로컬 디스크에서 파일이 이미 삭제된 경우. `skipped`로 처리되며, 다른 파일 마이그레이션에는 영향 없음.
