# S3 File Storage Setup Guide

Collavre supports storing uploaded files (images, avatars, etc.) on either **local disk** or **AWS S3**.
The default is **local disk**. Setting the S3 environment variables automatically switches to S3 storage.

## How Storage Selection Works

The storage backend is determined automatically by the presence of `AWS_S3_ACCESS_KEY_ID`:

| `AWS_S3_ACCESS_KEY_ID` | Storage | Description |
|------------------------|---------|-------------|
| **Empty (default)** | Local disk | Files stored in the server's `storage/` directory |
| **Has a value** | AWS S3 | Files stored in S3 with AES-256 encryption |

> No code changes required — switch storage backends using environment variables only.

---

## Local Disk Mode (Default)

No configuration needed. If the S3 environment variables are not set, files are stored on the local disk automatically.

⚠️ **Note**: In local mode, storage is limited by server disk capacity. When migrating servers, files must be copied manually.

---

## S3 Mode Setup

### 1. Required Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `AWS_S3_ACCESS_KEY_ID` | ✅ | IAM Access Key ID for S3 | `AKIA3C7HN7GC...` |
| `AWS_S3_SECRET_ACCESS_KEY` | ✅ | IAM Secret Access Key for S3 | `wJalrXUtnFEM...` |
| `AWS_S3_BUCKET` | ✅ | S3 bucket name | `collavre-uploads-production` |
| `AWS_REGION` | ❌ | AWS region (default: `ap-northeast-2`) | `us-east-1` |

### 2. Automated Setup Script

If the AWS CLI is installed, you can use the provided script to automatically create the bucket, IAM user, and access keys:

```bash
ruby bin/setup_s3.rb [environment] [aws_profile]

# Examples
ruby bin/setup_s3.rb production default
ruby bin/setup_s3.rb production my-aws-profile
```

The script performs the following steps:
1. Creates an S3 bucket (`collavre-uploads-{environment}`)
2. Blocks all public access
3. Enables default encryption (AES-256 SSE-S3)
4. Creates an IAM user with least-privilege access (bucket-scoped only)
5. Generates an Access Key
6. Writes credentials to `.env.s3`

After running the script, copy the values from `.env.s3` into your `.env.production`.

### 3. Manual Setup (Without AWS CLI)

#### 3-1. Create an S3 Bucket (AWS Console)

1. Go to the [AWS S3 Console](https://s3.console.aws.amazon.com/)
2. Click **Create bucket**
3. Configure:
   - Bucket name: `collavre-uploads-production` (or your preferred name)
   - Region: Choose a region close to your server
   - **Default encryption**: Amazon S3 managed keys (SSE-S3) — **AES-256** enabled
   - **Block public access**: **Block all public access** ✅ (must be checked)

#### 3-2. Create an IAM User (AWS Console)

1. Go to the [AWS IAM Console](https://console.aws.amazon.com/iam/)
2. Navigate to **Users** → **Add user**
3. Username: `s3-collavre-production`
4. **Attach policies directly** → **Create inline policy**:

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

> ⚠️ Replace `collavre-uploads-production` with your actual bucket name.

5. **Create access key** → Copy the Access Key ID and Secret Access Key

#### 3-3. Set Environment Variables

Add the following to your `.env.production` file:

```bash
# === S3 File Storage ===
AWS_S3_ACCESS_KEY_ID=AKIA3C7HN7GC...
AWS_S3_SECRET_ACCESS_KEY=wJalrXUtnFEM...
AWS_S3_BUCKET=collavre-uploads-production
# AWS_REGION=ap-northeast-2  # Default: ap-northeast-2. Set only if using a different region.
```

---

## Kamal Deployment

When using Kamal, environment variables must be configured in three places to reach the container:

### 1. `.env.production` (actual values)
```bash
AWS_S3_ACCESS_KEY_ID=AKIA...
AWS_S3_SECRET_ACCESS_KEY=...
AWS_S3_BUCKET=collavre-uploads-production
```

### 2. `.kamal/secrets` (variable references)
```bash
AWS_S3_ACCESS_KEY_ID=${AWS_S3_ACCESS_KEY_ID}
AWS_S3_SECRET_ACCESS_KEY=${AWS_S3_SECRET_ACCESS_KEY}
AWS_S3_BUCKET=${AWS_S3_BUCKET}
```

### 3. `config/deploy.yml` (`env.secret` list)
```yaml
env:
  secret:
    - AWS_S3_ACCESS_KEY_ID
    - AWS_S3_SECRET_ACCESS_KEY
    - AWS_S3_BUCKET
```

> These three files are already pre-configured in the codebase. You only need to enter the actual values in `.env.production`.

---

## Migrating Existing Files

A Rake task is included to migrate files from local disk to S3.

### Prerequisites
- S3 environment variables configured
- S3 bucket created

### How to Run

```bash
# Local development
bin/rails storage:migrate_to_s3

# Kamal production server
./kamal.sh app exec "bin/rails storage:migrate_to_s3"
```

### What It Does
1. Finds all blobs with `service_name` set to `local`
2. Determines the file owner and places files under user-specific folders (`users/{user_id}/`)
3. Uploads each file to S3 and updates the `key` and `service_name` in the database
4. Failed files retain `service_name: local`, so the task can be re-run safely

### S3 Folder Structure
```
collavre-uploads-production/
├── users/
│   ├── 42/abc123...   (user 42's files)
│   └── 87/def456...   (user 87's files)
└── unscoped/
    └── ghi789...      (files with unknown owner)
```

> ⚠️ It is recommended to run migration during a **maintenance window** on production servers due to file I/O and network load.

---

## Security Notes

- **Encryption**: All files stored in S3 are automatically encrypted with AES-256 (SSE-S3)
- **Access control**: The S3 bucket has all public access blocked; files are only accessible through the application
- **IAM least privilege**: The IAM user created by the setup script has access only to the specified bucket
- **URL handling**: Rails Active Storage uses redirect-based URLs — direct S3 URLs are never exposed to users

---

## Troubleshooting

### S3 Connection Failure
```
Aws::S3::Errors::InvalidAccessKeyId
```
→ Verify the `AWS_S3_ACCESS_KEY_ID` value. Check that the key is active in the IAM console.

### Bucket Access Denied
```
Aws::S3::Errors::AccessDenied
```
→ Verify the IAM user's policy includes the correct bucket. Check that `AWS_S3_BUCKET` matches the actual bucket name.

### Application Uses Local Storage Despite S3 Config
→ Check that `AWS_S3_ACCESS_KEY_ID` is set and not empty. If it's empty, the application automatically falls back to local storage.

### Missing Files During Migration
```
Blob 123 (image.png): local file missing, skipped
```
→ The local file was already deleted. The blob is skipped and does not affect the migration of other files.
