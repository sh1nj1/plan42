# frozen_string_literal: true

module CollavreLinear
  class ProjectLink < ApplicationRecord
    self.table_name = "linear_project_links"

    belongs_to :creative, class_name: "::Collavre::Creative"
    belongs_to :account, class_name: "CollavreLinear::Account"

    # linear_issue_links.project_link_id has an FK to this row; unlinking must
    # cascade so link.destroy! does not 500 once issues have synced.
    has_many :issue_links, class_name: "CollavreLinear::IssueLink", dependent: :destroy

    # The HMAC secret Linear signs webhook deliveries with. Linear GENERATES this
    # when the webhook is created — it can't be forced to a value we pick — so the
    # admin pastes Linear's secret in (we never mint our own; app actors also lack
    # the admin scope to auto-provision). Blank until pasted, which is fine: inbound
    # deliveries just 401 until then (WebhooksController). Encrypted at rest so a
    # DB/backup leak can't forge webhooks (mirrors Account tokens).
    encrypts :webhook_secret, deterministic: false

    enum :sync_state, { synced: 0, dirty: 1, syncing: 2, conflict: 3 }, prefix: false

    validates :linear_project_id, presence: true
    validates :team_id, presence: true

    # A team's single Linear webhook signs every delivery with one secret, so a
    # second project of an already-configured team inherits that secret rather
    # than asking the admin to paste it again (no-op for a brand-new team).
    before_create :adopt_team_webhook_secret

    scope :auto_syncable, -> { where(sync_state: %i[synced dirty]) }

    # Store the signing secret the admin copied from Linear's webhook settings,
    # propagating it to every sibling ProjectLink of the team. Linear signs all of
    # a team's deliveries with the one secret its single webhook carries, and
    # find_project_link resolves a delivery to an arbitrary team sibling, so all
    # must hold the same value or a sibling 401s. update_column applies encryption
    # (a raw write would leak plaintext); assign self last so its in-memory
    # attribute reflects the pasted value.
    def update_webhook_secret!(secret)
      self.class.where(team_id: team_id).where.not(id: id).find_each do |sibling|
        sibling.update_column(:webhook_secret, secret)
      end
      update_column(:webhook_secret, secret)
      secret
    end

    # The one signing secret a team's single Linear webhook uses, denormalized
    # across the team's sibling ProjectLinks. Returns any non-blank sibling's
    # value: a row created concurrently with the admin's paste can commit blank
    # (adopt ran before the paste was visible), and webhook verification may
    # resolve a delivery to that blank row — so the TEAM's secret, not one
    # arbitrary row's column, is the authority. Reads the decrypted attribute
    # (a raw pick would be ciphertext). Nil when the team has no secret yet.
    def self.team_webhook_secret(team_id)
      return if team_id.blank?

      where(team_id: team_id).filter_map { |link| link.webhook_secret.presence }.first
    end

    private

    # Inherit an existing team sibling's pasted secret so the admin configures one
    # webhook per team, not per project. webhook_secret is encrypted
    # (non-deterministic), so a raw column pick would return ciphertext that
    # re-encrypts into a double-wrapped value → HMAC mismatch; read the DECRYPTED
    # attribute off loaded siblings instead. Any sibling secret is valid since a
    # team shares one. Skips when already set or the team has no secret yet.
    def adopt_team_webhook_secret
      return if webhook_secret.present? || team_id.blank?

      self.webhook_secret = self.class.team_webhook_secret(team_id)
    end
  end
end
