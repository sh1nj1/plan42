class CreateGithubWebhookDeliveries < ActiveRecord::Migration[8.1]
  # Durable idempotency key for GitHub webhook deliveries. GitHub stamps the
  # `X-GitHub-Delivery` GUID per EVENT, not per delivery, so one GUID covers
  # redeliveries AND the fan-out to every hook configured on the repo. A
  # UNIQUE index therefore collapses both duplicate sources into one processed
  # request. It must live in the DB, not in a process-local cache: multiple app
  # instances share this database and each one receives its own copy.
  #
  # `processed_at` is what actually suppresses a redelivery. The row alone only
  # records that some request claimed the GUID; if that request then died, the
  # claim must not outlive it, or the redelivery would be answered 200 and the
  # event dropped for good.
  #
  # `claim_token` identifies WHICH run holds the claim. A run that outlives
  # STALE_CLAIM_AFTER has its claim taken over by the next delivery of the same
  # GUID, and without a token the original run's cleanup would act on the GUID
  # alone and delete the replacement's claim.
  def change
    create_table :github_webhook_deliveries do |t|
      t.string :delivery_guid, null: false
      t.string :event
      t.string :claim_token
      t.datetime :created_at, null: false
      t.datetime :processed_at
    end

    add_index :github_webhook_deliveries, :delivery_guid, unique: true
    add_index :github_webhook_deliveries, :created_at
  end
end
