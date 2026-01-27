# frozen_string_literal: true

class EncryptOauthTokens < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Encrypting User Google tokens" do
      encrypt_column(User, :google_access_token)
      encrypt_column(User, :google_refresh_token)
    end

    say_with_time "Encrypting GithubAccount tokens" do
      encrypt_column(GithubAccount, :token)
    end

    say_with_time "Encrypting NotionAccount tokens" do
      encrypt_column(NotionAccount, :token)
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
