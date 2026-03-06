# frozen_string_literal: true

# =============================================================================
# storage:migrate_to_s3
# =============================================================================
#
# 로컬 Active Storage 파일을 AWS S3로 마이그레이션하는 Rake 태스크.
#
# 수행 내용:
#   1. service_name이 "local"인 모든 ActiveStorage::Blob을 조회
#   2. 각 blob의 소유자(user)를 판별하여 사용자별 폴더 prefix 생성
#      - Collavre::Comment → comment.user_id
#      - Collavre::User   → record_id (본인 아바타)
#      - 소유자 불명       → "unscoped/" prefix
#   3. 로컬 파일을 S3에 업로드 (새 key로)
#   4. DB의 key와 service_name을 업데이트 (key → 새 prefix, service_name → "amazon")
#
# S3 폴더 구조 예시:
#   collavre-uploads-production/
#   ├── users/
#   │   ├── 42/abc123...   (user 42의 파일)
#   │   └── 87/def456...   (user 87의 파일)
#   └── unscoped/
#       └── ghi789...      (소유자 불명 파일)
#
# 사전 조건:
#   - config/storage.yml에 "amazon" 서비스가 정의되어 있어야 함
#   - AWS 환경변수 설정 완료 (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_BUCKET)
#   - S3 버킷 생성 완료 (bin/setup_s3.rb 참고)
#
# 사용법:
#   # 로컬 개발 환경
#   bin/rails storage:migrate_to_s3
#
#   # Kamal 운영서버 (점검 시간 권장)
#   ./kamal.sh app exec "bin/rails storage:migrate_to_s3"
#
# 주의사항:
#   - 운영서버에서는 점검 시간에 실행 권장 (파일 I/O + 네트워크 부하)
#   - 로컬 파일이 누락된 blob은 skip 처리 (로그에 경고 출력)
#   - 실패한 blob은 service_name이 "local"로 유지되므로 재실행 가능
# =============================================================================

namespace :storage do
  desc "Migrate local Active Storage files to S3 with user-prefixed keys"
  task migrate_to_s3: :environment do
    require "aws-sdk-s3"

    total = ActiveStorage::Blob.where(service_name: "local").count

    if total.zero?
      puts "No local blobs to migrate."
      exit
    end

    s3_service = ActiveStorage::Blob.services.fetch(:amazon)
    migrated = 0
    failed = 0
    skipped = 0

    puts "Migrating #{total} blobs from local to S3..."

    ActiveStorage::Blob.where(service_name: "local").find_each do |blob|
      # 소유자 판별: attachment의 record_type에 따라 user_id 추출
      attachment = blob.attachments.first
      user_id = if attachment
                  case attachment.record_type
                  when "Collavre::Comment"
                    attachment.record&.user_id
                  when "Collavre::User"
                    attachment.record_id
                  end
      end

      # 사용자별 폴더 prefix가 포함된 새 S3 key 생성
      new_key = if user_id
                  "users/#{user_id}/#{ActiveStorage::Blob.generate_unique_secure_token}"
      else
                  "unscoped/#{ActiveStorage::Blob.generate_unique_secure_token}"
      end

      begin
        # 로컬 파일을 임시 파일로 열어 S3에 업로드
        blob.open do |tempfile|
          s3_service.upload(new_key, tempfile,
            checksum: blob.checksum,
            content_type: blob.content_type)
        end

        # DB 업데이트: 새 key + service_name 변경 (callbacks 없이 직접 업데이트)
        blob.update_columns(key: new_key, service_name: "amazon")
        migrated += 1
        print "\r  Migrated: #{migrated}/#{total} (failed: #{failed})"
      rescue ActiveStorage::FileNotFoundError
        # 로컬 파일이 이미 삭제된 경우 — skip 처리
        skipped += 1
        Rails.logger.warn "Blob #{blob.id} (#{blob.filename}): local file missing, skipped"
      rescue => e
        # 기타 오류 — service_name이 "local"로 유지되어 재실행 시 재시도 가능
        failed += 1
        Rails.logger.error "Blob #{blob.id} (#{blob.filename}): #{e.message}"
      end
    end

    puts "\n\nDone!"
    puts "  Migrated: #{migrated}"
    puts "  Skipped (file missing): #{skipped}"
    puts "  Failed: #{failed}"
    puts "  Total: #{total}"
  end
end
