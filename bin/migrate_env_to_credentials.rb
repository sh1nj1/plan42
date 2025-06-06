#!/usr/bin/env ruby
require 'yaml'

ENV_FILE = ".env.ses"
TMP_FILE = ".tmp_credentials.yml"

# 1. .env 파일 로딩
def load_env_file(path)
  env = {}
  File.readlines(path).each do |line|
    next if line.strip.start_with?('#') || !line.include?('=')
    key, value = line.strip.split('=', 2)
    env[key] = value
  end
  env
end

# 2. 기존 credentials 복호화
def load_existing_credentials
  output = `bin/rails credentials:show 2>/dev/null`
  return {} if output.strip.empty?
  YAML.safe_load(output, aliases: true) || {}
rescue Psych::SyntaxError => e
  puts "❌ credentials.yml.enc 구문 오류: #{e.message}"
  exit 1
end

# 3. 병합
def merge_aws_credentials(existing, env)
  existing['aws'] ||= {}
  existing['aws']['access_key_id']     = env['AWS_ACCESS_KEY_ID']
  existing['aws']['secret_access_key'] = env['AWS_SECRET_ACCESS_KEY']
  existing['aws']['region']            = env['AWS_REGION']
  existing['aws']['smtp_username']     = env['AWS_SMTP_USERNAME']
  existing['aws']['smtp_password']     = env['AWS_SMTP_PASSWORD']
  existing
end

# 4. credentials.yml.enc 업데이트
def update_credentials_file(data)
  File.write(TMP_FILE, data.to_yaml)
  system("EDITOR=\"cp #{TMP_FILE}\" bin/rails credentials:edit")
  File.delete(TMP_FILE)
end

# 실행
unless File.exist?(ENV_FILE)
  puts "❌ #{ENV_FILE} 파일이 없습니다."
  exit 1
end

env_data     = load_env_file(ENV_FILE)
credentials  = load_existing_credentials
merged_data  = merge_aws_credentials(credentials, env_data)

update_credentials_file(merged_data)

puts "✅ AWS 설정이 credentials.yml.enc에 성공적으로 병합되었습니다."
