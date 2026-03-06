#!/usr/bin/env ruby
require "json"

# =============================================================================
# setup_s3.rb — Automated AWS S3 bucket and IAM user setup for Active Storage
# =============================================================================
#
# Creates an S3 bucket with encryption and public access blocked,
# then creates an IAM user with least-privilege access (bucket-scoped only)
# and generates access keys.
#
# Usage:
#   ruby bin/setup_s3.rb [environment] [aws_profile]
#
# Examples:
#   ruby bin/setup_s3.rb production default
#   ruby bin/setup_s3.rb staging my-aws-profile
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - Valid AWS profile with IAM and S3 permissions
# =============================================================================

# === Input parameters ===
rails_env = ARGV[0] || "production"
profile   = ARGV[1] || "default"
region    = "ap-northeast-2"
bucket    = "collavre-uploads-#{rails_env}"
iam_user  = "s3-collavre-#{rails_env}"
env_file  = ".env.s3"

def aws(command, profile)
  output = `AWS_PROFILE=#{profile} #{command}`
  unless $?.success?
    puts "❌ Error running: #{command}"
    puts output
    exit 1
  end
  output
end

puts "▶️ 1. Creating S3 bucket: #{bucket} (#{region})"
bucket_create_output = `AWS_PROFILE=#{profile} aws s3api create-bucket \
  --bucket #{bucket} \
  --region #{region} \
  --create-bucket-configuration LocationConstraint=#{region} 2>&1`
if bucket_create_output.include?("BucketAlreadyOwnedByYou") || bucket_create_output.include?("BucketAlreadyExists")
  puts "ℹ️ Bucket #{bucket} already exists."
elsif !$?.success?
  puts "❌ Failed to create bucket: #{bucket_create_output}"
  exit 1
else
  puts "✅ Bucket created"
end

puts "▶️ 2. Blocking all public access"
aws("aws s3api put-public-access-block \
  --bucket #{bucket} \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true", profile)
puts "✅ Public access blocked"

puts "▶️ 3. Enabling default encryption (AES-256 SSE-S3)"
aws("aws s3api put-bucket-encryption \
  --bucket #{bucket} \
  --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"},\"BucketKeyEnabled\":true}]}'", profile)
puts "✅ Default encryption enabled"

puts "▶️ 4. Creating IAM user: #{iam_user}"
user_create_output = `AWS_PROFILE=#{profile} aws iam create-user --user-name #{iam_user} 2>&1`
if user_create_output.include?("EntityAlreadyExists")
  puts "ℹ️ IAM user #{iam_user} already exists."
elsif !$?.success?
  puts "❌ Failed to create IAM user: #{user_create_output}"
  exit 1
else
  puts "✅ IAM user created"
end

puts "▶️ 5. Attaching inline policy (bucket-scoped access only)"
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
puts "✅ Inline policy attached (#{bucket} bucket only)"

puts "▶️ 6. Generating access key"
access_key_output = aws("aws iam create-access-key --user-name #{iam_user} --output json", profile)
access_info = JSON.parse(access_key_output)["AccessKey"]
access_key = access_info["AccessKeyId"]
secret_key = access_info["SecretAccessKey"]

puts "▶️ 7. Writing #{env_file}"
File.write(env_file, <<~ENV)
  AWS_S3_ACCESS_KEY_ID=#{access_key}
  AWS_S3_SECRET_ACCESS_KEY=#{secret_key}
  AWS_S3_BUCKET=#{bucket}
  AWS_REGION=#{region}
ENV

puts <<~DONE

  ✅ Done! #{env_file} has been created.

  📋 Next steps:
  1. Copy the values from #{env_file} into .env.#{rails_env}
  2. Verify .kamal/secrets has the same environment variables
  3. Verify config/deploy.yml env.secret includes AWS_S3_ACCESS_KEY_ID, AWS_S3_SECRET_ACCESS_KEY, AWS_S3_BUCKET
  4. After deployment, run the migration on the production server:
     ./kamal.sh app exec "bin/rails storage:migrate_to_s3"

  🔐 Security notes:
  - IAM user #{iam_user} has access only to the #{bucket} bucket
  - S3 bucket has default encryption (AES-256) and all public access blocked
DONE
