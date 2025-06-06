#!/usr/bin/env ruby
require 'json'
require 'base64'
require 'openssl'

# === 입력 파라미터 ===
domain   = ARGV[0]
profile  = ARGV[1] || 'default'
region   = 'ap-northeast-2'
iam_user = 'ses-rails-sender'
env_file = '.env.ses'

if domain.nil? || domain.strip.empty?
  puts "❌ 사용법: ruby setup_ses.rb yourdomain.com [aws_profile]"
  exit 1
end

def aws(command, profile)
  output = `AWS_PROFILE=#{profile} #{command}`
  unless $?.success?
    puts "❌ 오류 발생: #{command}"
    puts output
    exit 1
  end
  output
end

def generate_smtp_password(secret_key)
  message = "SendRawEmail"
  version = 0x04

  hmac = OpenSSL::HMAC.digest('sha256', secret_key, message)
  signature = [version.chr + hmac].join
  Base64.strict_encode64(signature)
end

puts "▶️ 1. SES 도메인 인증 요청 중: #{domain}"
verify_output = aws("aws ses verify-domain-identity --region #{region} --domain #{domain} --output json", profile)
token = JSON.parse(verify_output)['VerificationToken']

puts "\n📌 DNS에 다음 TXT 레코드를 추가하세요:\n"
puts "_amazonses.#{domain} TXT \"#{token}\"\n"

puts "▶️ 2. IAM 사용자 생성: #{iam_user}"
user_create_output = `AWS_PROFILE=#{profile} aws iam create-user --user-name #{iam_user} 2>&1`
puts "ℹ️ 사용자 #{iam_user}는 이미 존재합니다." if user_create_output.include?('EntityAlreadyExists')

puts "▶️ 3. IAM 정책 연결: AmazonSESFullAccess"
aws("aws iam attach-user-policy --user-name #{iam_user} --policy-arn arn:aws:iam::aws:policy/AmazonSESFullAccess", profile)

puts "▶️ 4. Access Key 발급"
access_key_output = aws("aws iam create-access-key --user-name #{iam_user} --output json", profile)
access_info = JSON.parse(access_key_output)['AccessKey']
access_key = access_info['AccessKeyId']
secret_key = access_info['SecretAccessKey']

puts "▶️ 5. SMTP 암호 생성"
smtp_password = generate_smtp_password(secret_key)

puts "▶️ 6. .env.ses 파일 생성"
File.write(env_file, <<~ENV)
  AWS_ACCESS_KEY_ID=#{access_key}
  AWS_SECRET_ACCESS_KEY=#{secret_key}
  AWS_REGION=#{region}
  AWS_SMTP_USERNAME=#{access_key}
  AWS_SMTP_PASSWORD=#{smtp_password}
ENV

puts "\n✅ 완료: .env.ses 파일이 생성되었습니다."
puts "🔐 DNS 레코드를 추가한 후 AWS SES 콘솔에서 도메인 상태가 'verified'가 되는지 확인하세요."
