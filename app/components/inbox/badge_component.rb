module Inbox
  class BadgeComponent < ViewComponent::Base
    attr_reader :badge_id, :show_zero

      def initialize(user: nil, count: nil, badge_id: "desktop-inbox-badge", show_zero: false)
      @user = user
      @count = count
      @badge_id = badge_id
      @show_zero = show_zero
    end

    def count
      @count || InboxItem.where(owner: @user, state: "new").count
    end
  end
end
