class BackfillAgentProfileCreatorShares < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Agent profile creatives created before the creator-admin grant landed have
  # no share, leaving their human creator without any Creative-level path to the
  # profile. Grant the same admin share here.
  #
  # Only AI agents: created_by_id is also set on humans invited by another user,
  # and a person's own profile must not be exposed to whoever created them.
  def up
    Collavre::User
      .where.not(created_by_id: nil)
      .where.not(llm_vendor: [ nil, "" ])
      .find_each(batch_size: 200) do |agent|
        profile = Collavre::Creative.where(user_id: agent.id, kind: "profile").order(:id).first
        next unless profile
        next if Collavre::CreativeShare.exists?(creative_id: profile.id, user_id: agent.created_by_id)

        share = Collavre::CreativeShare.new(
          creative_id: profile.id,
          user_id: agent.created_by_id,
          shared_by_id: agent.id,
          permission: :admin
        )
        share.skip_recipient_notification = true
        share.save!
      rescue => e
        Rails.logger.error("[BackfillAgentProfileCreatorShares] agent #{agent.id}: #{e.message}")
      end
  end

  def down
    # No-op: a share cannot be distinguished from one the creator has since
    # adjusted deliberately, so removing them could revoke intended access.
  end
end
