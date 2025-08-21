class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache, :user

  def user
    session&.user || User.anonymous
  end
end
