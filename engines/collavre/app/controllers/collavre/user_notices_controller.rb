module Collavre
  # Records what the user did with a notice-bar notice. The bar updates
  # optimistically, so these actions answer with an empty 204.
  class UserNoticesController < ApplicationController
    before_action :set_notice

    # Closing a non-mission notice hides it for good.
    def dismiss
      return head(:unprocessable_entity) if @notice.mission?

      record!(:dismissed)
    end

    # Missions cannot be dismissed, only put off until they are done.
    def snooze
      return head(:unprocessable_entity) unless @notice.mission?

      record!(:snoozed, snoozed_until: UserNotice::SNOOZE_DURATION.from_now)
    end

    # Following a non-mission call to action finishes it. Missions complete
    # only from their server-side event.
    def complete
      return head(:unprocessable_entity) if @notice.mission?

      record!(:completed)
    end

    # Undo for a snooze or dismissal made moments ago.
    def restore
      state = UserNotice.find_by(user: Current.user, notice_key: @notice.key.to_s)
      return head(:unprocessable_entity) unless state&.snoozed? || state&.dismissed?

      record!(:pending)
    end

    private

    def set_notice
      @notice = NoticeRegistry.find(params[:key])
      head :not_found unless @notice&.visible_to?(Current.user)
    end

    def record!(status, snoozed_until: nil)
      UserNotice.record!(Current.user, @notice.key, status, snoozed_until: snoozed_until)
      head :no_content
    end
  end
end
