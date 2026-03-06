#!/usr/bin/env ruby
require "json"

# === 입력 파라미터 ===
rails_env = ARGV[0] || "production"
profile   = ARGV[1] || "default"
region    = "ap-northeast-2"
bucket    = "collavre-uploads-#{rails_env}"
iam_user  = "s3-collavre-#{rails_env}"
env_file  = ".env.s3"

def aws(command, profile)
  output = `AWS_PROFILE=#{profile} #{command}`
  unless $?.success?
    puts "❌ 오류 발생: #{command}"
    puts output
    exit 1
  end
  output
end

puts "▶️ 1. S3 버킷 생성: #{bucket} (#{region})"
bucket_create_output = `AWS_PROFILE=#{profile} aws s3api create-bucket \
  --bucket #{bucket} \
  --region #{region} \
  --create-bucket-configuration LocationConstraint=#{region} 2>&1`
if bucket_create_output.include?("BucketAlreadyOwnedByYou") || bucket_create_output.include?("BucketAlreadyExists")
  puts "ℹ️ 버킷 #{bucket}은 이미 존재합니다."
elsif !$?.success?
  puts "❌ 버킷 생성 실패: #{bucket_create_output}"
  exit 1
else
  puts "✅ 버킷 생성 완료"
end

puts "▶️ 2. Public Access 전면 차단"
aws("aws s3api put-public-access-block \
  --bucket #{bucket} \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true", profile)
puts "✅ Public Access 차단 완료"

puts "▶️ 3. 기본 암호화 설정 (AES-256 SSE-S3)"
aws("aws s3api put-bucket-encryption \
  --bucket #{bucket} \
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}'", profile)
puts "✅ 기본 암호화 설정 완료"

puts "▶️ 4. IAM 사용자 생성: #{iam_user}"
user_create_output = `AWS_PROFILE=#{profile} aws iam create-user --user-name #{iam_user} 2>&1`
if user_create_output.include?("EntityAlreadyExists")
  puts "ℹ️ 사용자 #{iam_user}는 이미 존재합니다."
elsif !$?.success?
  puts "❌ IAM 사용자 생성 실패: #{user_create_output}"
  exit 1
else
  puts "✅ IAM 사용자 생성 완료"
end

puts "▶️ 5. IAM 인라인 정책 연결 (해당 버킷만 접근 허용)"
policy = {
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "AllowS3BucketAccess",
      Effect: "Allow",
      Action: [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      Resource: [
        "arn:aws:s3:::#{bucket}",
        "arn:aws:s3:::#{bucket}/*"
      ]
    }
  ]
}.to_json

aws("aws iam put-user-policy \
  --user-name #{iam_user} \
  --policy-name S3CollavreAccess \
  --policy-document '#{policy}'", profile)
puts "✅ 인라인 정책 연결 완료 (#{bucket} 버킷만 허용)"

puts "▶️ 6. Access Key 발급"
access_key_output = aws("aws iam create-access-key --user-name #{iam_user} --output json", profile)
access_info = JSON.parse(access_key_output)["AccessKey"]
access_key = access_info["AccessKeyId"]
secret_key = access_info["SecretAccessKey"]

puts "▶️ 7. #{env_file} 파일 생성"
File.write(env_file, <<~ENV)
  AWS_S3_ACCESS_KEY_ID=#{access_key}
  AWS_S3_SECRET_ACCESS_KEY=#{secret_key}
  AWS_S3_BUCKET=#{bucket}
  AWS_REGION=#{region}
ENV

puts <<~DONE

  ✅ 완료: #{env_file} 파일이 생성되었습니다.

  📋 다음 단계:
  1. #{env_file}의 값을 .env.#{rails_env}에 복사하세요
  2. .kamal/secrets에도 동일한 환경변수가 설정되어 있는지 확인하세요
  3. config/deploy.yml의 env.secret에 AWS_S3_ACCESS_KEY_ID, AWS_S3_SECRET_ACCESS_KEY, AWS_S3_BUCKET이 있는지 확인하세요
  4. 배포 후 운영서버에서 마이그레이션을 실행하세요:
     ./kamal.sh app exec "bin/rails storage:migrate_to_s3"

  🔐 보안 참고:
  - IAM 사용자 #{iam_user}는 #{bucket} 버킷에만 접근 가능합니다
  - S3 버킷은 기본 암호화(AES-256) + Public Access 전면 차단 상태입니다
DONE
