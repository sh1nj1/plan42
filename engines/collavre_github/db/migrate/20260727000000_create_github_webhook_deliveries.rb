class CreateGithubWebhookDeliveries < ActiveRecord::Migration[8.1]
  # Durable idempotency key for GitHub webhook deliveries. GitHub stamps every
  # delivery with a unique `X-GitHub-Delivery` GUID and reuses that GUID for
  # redeliveries AND for the fan-out to every hook configured on the repo. A
  # UNIQUE index therefore collapses both duplicate sources into one processed
  # request. It must live in the DB, not in a process-local cache: multiple app
  # instances share this database and each one receives its own copy.
  def change
    create_table :github_webhook_deliveries do |t|
      t.string :delivery_guid, null: false
      t.string :event
      t.datetime :created_at, null: false
    end

    add_index :github_webhook_deliveries, :delivery_guid, unique: true
    add_index :github_webhook_deliveries, :created_at
  end
end
