module Collavre
  # Records notice actions and serves authoritative feeds at notice deadlines.
  class UserNoticesController < ApplicationController
    before_action :set_notice, except: :index

    def index
      response.headers["Cache-Control"] = "no-store"
      render json: { items: Notices::Feed.new(Current.user).items, refresh_at: Notices::RefreshDeadline.for(Current.user) }
    end

    # Closing a non-mission notice hides it for good.
    def dismiss
      return head(:unprocessable_entity) if @notice.mission?

      record!(:dismissed)
    end

    # Missions cannot be dismissed, only put off until they are done. A snooze
    # arriving after completion is ignored (see UserNotice.record!).
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

      restored = UserNotice.record!(Current.user, @notice.key, :pending)
      return head(:unprocessable_entity) unless restored.pending?

      broadcast_mutation
      head :no_content
    end

    private

    def set_notice
      @notice = NoticeRegistry.find(params[:key])
      head :not_found unless @notice&.visible_to?(Current.user)
    end

    def record!(status, snoozed_until: nil)
      state = UserNotice.record!(Current.user, @notice.key, status, snoozed_until: snoozed_until)
      response.headers["X-Notice-Snoozed-Until"] = state.snoozed_until.iso8601(3) if state.snoozed?
      broadcast_mutation
      head :no_content
    end

    def broadcast_mutation
      Notices::Tracker.broadcast(Current.user, changed: @notice.key)
    end
  end
end
