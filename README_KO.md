# README

[🇰🇷 (한국어)](./README_KO.md) | [🇬🇧 (English)](./README.md)

이것은 [Ruby on Rails 시작 문서](getting_started_ko.md)를 위한 작동 코드입니다.

런타임 버전 정보:

```bash
store % ruby -v
ruby 3.4.1 (2024-12-25 revision 48d4efcb85) +PRISM [arm64-darwin24]
store % rails -v
Rails 8.0.1
```

## Getting Started

* `bin/rails db:migrate` - 데이터베이스 마이그레이션 실행 (기본적으로 sqlite3 사용)
* `bin/rails db:seed` - 데이터베이스에 시드 데이터 삽입 (db/seeds.rb의 데이터)
* `bin/rails server` - Rails 서버 시작

## AWS EC2에 배포

- [AWS EC2에 배포하기](deploy_to_ec2.md)

## Render에 배포

이 애플리케이션은 Render에 배포할 수 있도록 구성되어 있습니다.

배포 방법:

1. [![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/sh1nj1/ror_getting_started)
2. Render에서 다음 환경 변수를 설정해야 합니다:
   - `RAILS_MASTER_KEY`: 로컬 `config/master.key` 파일에서 복사
   - `DEFAULT_USER_EMAIL`: 기본 관리자 사용자의 이메일 (예: admin@example.com)
   - `DEFAULT_USER_PASSWORD`: 기본 관리자 사용자의 비밀번호
   배포 버튼을 클릭한 후 이러한 환경 변수를 설정하라는 메시지가 표시됩니다.
3. "Apply"를 클릭하여 배포를 시작합니다. Render는 `render.yaml` 구성에 명시된 대로 웹 서비스와 PostgreSQL 데이터베이스를 자동으로 생성합니다.
