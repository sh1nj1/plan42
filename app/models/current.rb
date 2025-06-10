class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache
  delegate :user, to: :session, allow_nil: true
end
