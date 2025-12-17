class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache
  attribute :user

  def user
    super || session&.user
  end
end
