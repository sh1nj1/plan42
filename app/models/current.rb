class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache
  attribute :creative_permission_cache
  delegate :user, to: :session, allow_nil: true

  def self.clear_permission_cache!
    self.creative_permission_cache&.clear
  end
end
