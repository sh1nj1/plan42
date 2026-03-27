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
        visible_comments = @creative.comments.where(private: false)
                                             .or(@creative.comments.where(user_id: @user.id))
        pointer = CommentReadPointer.find_by(user: @user, creative: @creative)
        last_read_id = pointer&.last_read_comment_id

        scope = last_read_id ? visible_comments.where("comments.id > ?", last_read_id) : visible_comments
        scope.count
      end
    end
  end
end
