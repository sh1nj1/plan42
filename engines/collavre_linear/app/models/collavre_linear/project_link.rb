# frozen_string_literal: true

module CollavreLinear
  class ProjectLink < ApplicationRecord
    self.table_name = "linear_project_links"

    belongs_to :creative, class_name: "::Collavre::Creative"
    belongs_to :account, class_name: "CollavreLinear::Account"

    # linear_issue_links.project_link_id has an FK to this row; unlinking must
    # cascade so link.destroy! does not 500 once issues have synced.
    has_many :issue_links, class_name: "CollavreLinear::IssueLink", dependent: :destroy

    # The HMAC secret Linear signs webhook deliveries with — encrypted at rest so
    # a DB/backup leak can't be used to forge webhooks (mirrors Account tokens).
    encrypts :webhook_secret, deterministic: false

    enum :sync_state, { synced: 0, dirty: 1, syncing: 2, conflict: 3 }, prefix: false

    validates :linear_project_id, presence: true
    validates :team_id, presence: true
    validates :webhook_secret, presence: true

    before_validation :ensure_webhook_secret
    before_save :ensure_webhook_secret

    scope :auto_syncable, -> { where(sync_state: %i[synced dirty]) }

    # Roll the team's shared HMAC secret and return the new value. Linear signs
    # every delivery for a team with the one secret its webhook was registered
    # with, so all sibling ProjectLinks must roll together or a sibling 401s.
    # The webhook is set up by hand (no admin scope to auto-provision), so this
    # only rotates the stored secret — the user re-pastes it into Linear's
    # webhook config. update_column applies encryption (a raw write would leak
    # plaintext); assign self last so its in-memory attribute reflects the roll.
    def rotate_webhook_secret!
      new_secret = SecureRandom.hex(20)
      self.class.where(team_id: team_id).where.not(id: id).find_each do |sibling|
        sibling.update_column(:webhook_secret, new_secret)
      end
      update_column(:webhook_secret, new_secret)
      new_secret
    end

    private

    # Linear signs every delivery for a team with ONE secret, and the manual
    # (no-admin) setup registers a single team webhook. So all ProjectLinks for
    # the same team must share one secret — otherwise a sibling verifies the
    # team webhook with a secret Linear never uses and inbound 401s. Adopt an
    # existing team secret (even from a sibling with no stored webhook_id, which
    # is always the case under manual setup); only generate for a brand-new team.
    def ensure_webhook_secret
      return if webhook_secret.present?

      self.webhook_secret = adopt_team_webhook_secret || SecureRandom.hex(20)
    end

    # webhook_secret is encrypted (non-deterministic), so a raw column pick would
    # return ciphertext and re-encrypting it double-wraps the value → HMAC mismatch.
    # Load sibling ProjectLinks for the team and read the DECRYPTED attribute; any
    # sibling secret is valid since a team shares one.
    def adopt_team_webhook_secret
      return nil if team_id.blank?

      self.class.where(team_id: team_id).where.not(id: id)
          .filter_map(&:webhook_secret).find(&:present?)
    end
  end
end
