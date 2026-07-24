class AllowNullWebhookSecretOnLinearProjectLinks < ActiveRecord::Migration[8.0]
  # Linear generates the webhook signing secret when the webhook is created and
  # won't let us pick it, so a ProjectLink is created without one and the admin
  # pastes Linear's value in afterward. Relax the original NOT NULL accordingly.
  def change
    change_column_null :linear_project_links, :webhook_secret, true
  end
end
