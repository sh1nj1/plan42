module Inbox
  class BadgeComponent < ViewComponent::Base
    attr_reader :badge_id

    def initialize(user: nil, count: nil, badge_id: "inbox-badge")
      @user = user
      @count = count
      @badge_id = badge_id
    end

    def count
      @count || InboxItem.where(owner: @user, state: "new").count
    end
  end
end
