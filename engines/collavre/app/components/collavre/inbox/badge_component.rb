module Collavre
  module Inbox
    class BadgeComponent < ViewComponent::Base
      attr_reader :badge_id, :show_zero

      def initialize(user: nil, creative: nil, count: nil, badge_id: "desktop-inbox-badge", show_zero: false)
        @user = user
        @creative = creative
        @count = count
        @badge_id = badge_id
        @show_zero = show_zero
      end

      def count
        return @count if @count

        if @creative && @user
          # Use CommentReadPointer-based unread count for inbox creative
          unread_count_for_creative
        else
          # Legacy fallback: InboxItem count
          InboxItem.where(owner: @user, state: "new").count
        end
      end

      private

      def unread_count_for_creative
        badge_index = Creatives::CommentBadgeIndex.new(user: @user)
        badge_index.index([ @creative.effective_origin ])
        badge_index.unread_count_for(@creative.effective_origin)
      end
    end
  end
end
