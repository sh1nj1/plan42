class Current < ActiveSupport::CurrentAttributes
  attribute :session
  attribute :creative_share_cache

  def user
    session&.user || User.anonymous
  end
end
