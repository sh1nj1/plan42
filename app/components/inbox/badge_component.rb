module Inbox
  class BadgeComponent < ViewComponent::Base
    def initialize(user:)
      @user = user
    end

    def count
      InboxItem.where(owner: @user, state: "new").count
    end
  end
end
