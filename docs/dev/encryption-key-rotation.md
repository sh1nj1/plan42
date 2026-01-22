# Encryption Key Rotation Guide

This document describes how to rotate Active Record encryption keys and re-encrypt existing data.

## Background

Collavre uses Rails Active Record Encryption for sensitive fields like `User#llm_api_key`. By default, encryption keys are derived from `secret_key_base` as a fallback (see `config/initializers/active_record_encryption.rb`).

For production environments, dedicated encryption keys should be configured via environment variables or credentials.

## Encrypted Fields

| Model | Attribute | Deterministic |
|-------|-----------|---------------|
| User | llm_api_key | No |
| User | google_access_token | No |
| User | google_refresh_token | No |
| GithubAccount | token | No |
| NotionAccount | token | No |

## Key Rotation Procedure

### Step 1: Generate New Keys

```bash
bin/rails db:encryption:init
```

This outputs three values:
- `primary_key`
- `deterministic_key`
- `key_derivation_salt`

### Step 2: Configure New Keys

Add the new keys to your environment. Choose one method:

**Option A: Environment Variables**
```bash
export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="<generated_primary_key>"
export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="<generated_deterministic_key>"
export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="<generated_salt>"
```

**Option B: Rails Credentials**
```bash
bin/rails credentials:edit
```

```yaml
active_record_encryption:
  primary_key: <generated_primary_key>
  deterministic_key: <generated_deterministic_key>
  key_derivation_salt: <generated_salt>
```

### Step 3: Configure Previous Keys (for migration)

Update `config/initializers/active_record_encryption.rb` to include the previous keys:

```ruby
# frozen_string_literal: true

encryption_config = Rails.application.config.active_record.encryption

# Skip if keys are already configured
if encryption_config.primary_key.present? &&
   encryption_config.deterministic_key.present? &&
   encryption_config.key_derivation_salt.present?

  # Add previous fallback keys for migration period
  key_generator = ActiveSupport::KeyGenerator.new(
    Rails.application.secret_key_base,
    iterations: 1000
  )
  key_len = ActiveSupport::MessageEncryptor.key_len

  encryption_config.previous_schemes << {
    primary_key: key_generator.generate_key("active_record_encryption_primary_key", key_len),
    deterministic_key: key_generator.generate_key("active_record_encryption_deterministic_key", key_len),
    key_derivation_salt: "active_record_encryption_salt"
  }
else
  # Fallback for development (existing behavior)
  key_generator = ActiveSupport::KeyGenerator.new(
    Rails.application.secret_key_base,
    iterations: 1000
  )
  key_len = ActiveSupport::MessageEncryptor.key_len

  encryption_config.primary_key ||= key_generator.generate_key("active_record_encryption_primary_key", key_len)
  encryption_config.deterministic_key ||= key_generator.generate_key("active_record_encryption_deterministic_key", key_len)
  encryption_config.key_derivation_salt ||= "active_record_encryption_salt"
end
```

### Step 4: Verify Decryption

Before re-encrypting, verify all existing data can be decrypted:

```bash
bin/rails encryption:verify
```

This reads all encrypted fields and reports any decryption errors.

### Step 5: Re-encrypt Data

**Dry run first:**
```bash
DRY_RUN=1 bin/rails encryption:reencrypt
```

**Perform actual re-encryption:**
```bash
bin/rails encryption:reencrypt
```

This task:
1. Finds all records with encrypted attributes
2. Decrypts using either current or previous keys
3. Re-encrypts using the new primary key
4. Saves the record

### Step 6: Remove Previous Keys (optional)

After confirming all data is re-encrypted, you can remove the `previous_schemes` configuration. However, keeping it for a transition period is recommended in case of rollback needs.

## Troubleshooting

### Decryption Errors

If `encryption:verify` reports errors:

1. Check that `secret_key_base` hasn't changed since the data was encrypted
2. Verify the previous keys configuration matches the original encryption setup
3. For individual records, you may need to manually fix or reset the data

### Rolling Back

If you need to roll back to the old keys:

1. Remove the new key environment variables/credentials
2. The initializer will fall back to deriving keys from `secret_key_base`
3. Data encrypted with new keys will be unreadable until new keys are restored

## Adding New Encrypted Fields

When adding encryption to a new model/attribute:

1. Add `encrypts :attribute_name` to the model
2. Update `lib/tasks/encryption.rake` to include the new model and attribute in `encrypted_models`
3. Update this document's "Encrypted Fields" table

## References

- [Rails Active Record Encryption Guide](https://guides.rubyonrails.org/active_record_encryption.html)
- [Key Rotation](https://guides.rubyonrails.org/active_record_encryption.html#key-rotation)
