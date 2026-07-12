# frozen_string_literal: true

class EncryptOauthTokens < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Encrypting User Google tokens" do
      encrypt_column(User, :google_access_token)
      encrypt_column(User, :google_refresh_token)
    end

    # Vendor account tokens live in vendor engines. Guard each block so this
    # core migration runs cleanly on an install where the engine is absent
    # (the constant would otherwise raise NameError). When the engine is
    # present on a fresh DB there are no plaintext rows yet, so the block is a
    # no-op; encryption of new writes is handled by the model's `encrypts`.
    if defined?(CollavreGithub::Account)
      say_with_time "Encrypting CollavreGithub::Account tokens" do
        encrypt_column(CollavreGithub::Account, :token)
      end
    end

    if defined?(CollavreNotion::NotionAccount)
      say_with_time "Encrypting CollavreNotion::NotionAccount tokens" do
        encrypt_column(CollavreNotion::NotionAccount, :token)
      end
    end
  end

  def down
    # No-op: Decryption happens automatically when reading encrypted values
    # The `encrypts` declaration in the model handles transparent decryption
  end

  private

  def encrypt_column(model, attribute)
    table_name = model.table_name

    # Read plaintext values directly from database using raw SQL
    records_to_encrypt = ActiveRecord::Base.connection.select_all(
      "SELECT id, #{attribute} FROM #{table_name} WHERE #{attribute} IS NOT NULL"
    ).to_a

    records_to_encrypt.each do |row|
      record_id = row["id"]
      plaintext_value = row[attribute.to_s]

      # Skip if already encrypted (value looks like JSON with encryption markers)
      next if plaintext_value.nil? || encrypted?(plaintext_value)

      # Encrypt the plaintext value using the model's encryptor
      encryptor = model.type_for_attribute(attribute)
      encrypted_value = encryptor.serialize(plaintext_value)

      # Write encrypted value directly to database
      ActiveRecord::Base.connection.execute(
        "UPDATE #{table_name} SET #{attribute} = #{ActiveRecord::Base.connection.quote(encrypted_value)} WHERE id = #{record_id}"
      )
    end
  end

  def encrypted?(value)
    # Active Record Encryption uses JSON format starting with specific markers
    return false unless value.is_a?(String)

    value.start_with?("{") && value.include?('"p":')
  rescue StandardError
    false
  end
end
