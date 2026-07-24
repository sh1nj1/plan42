# frozen_string_literal: true

# Re-encrypt pre-existing plaintext webhook_secret values in place now that
# CollavreGithub::RepositoryLink declares `encrypts :webhook_secret`. Reads the
# raw column with SQL (bypassing the model so we get plaintext, not a decrypt
# attempt), skips rows already in Active Record Encryption's JSON envelope, and
# writes the encrypted payload back with the model's own encryptor so the format
# matches runtime reads. `support_unencrypted_data = true` keeps unmigrated rows
# readable, so this is safe to run without downtime.
class EncryptGithubRepositoryLinkWebhookSecrets < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Encrypting GitHub repository link webhook secrets" do
      encrypt_column(CollavreGithub::RepositoryLink, :webhook_secret)
    end
  end

  def down
    # No-op: `encrypts` decrypts transparently, and support_unencrypted_data
    # keeps any remaining plaintext readable.
  end

  private

  def encrypt_column(model, attribute)
    table_name = model.table_name
    connection = ActiveRecord::Base.connection

    rows = connection.select_all(
      "SELECT id, #{attribute} FROM #{table_name} WHERE #{attribute} IS NOT NULL"
    ).to_a

    encryptor = model.type_for_attribute(attribute)

    rows.each do |row|
      plaintext = row[attribute.to_s]
      next if plaintext.nil? || encrypted?(plaintext)

      encrypted = encryptor.serialize(plaintext)
      connection.execute(
        "UPDATE #{table_name} SET #{attribute} = #{connection.quote(encrypted)} WHERE id = #{connection.quote(row['id'])}"
      )
    end
  end

  # Active Record Encryption stores a JSON envelope containing a "p" (payload)
  # key; treat anything already in that shape as encrypted and leave it alone.
  def encrypted?(value)
    return false unless value.is_a?(String)

    value.start_with?("{") && value.include?('"p":')
  rescue StandardError
    false
  end
end
