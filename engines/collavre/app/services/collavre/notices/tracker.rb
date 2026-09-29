module Collavre
  module Notices
    # Completes notices from instrumented domain events (`*.collavre`) and pushes
    # the refreshed notice bar to the user's open tabs, so the next onboarding
    # mission appears without a reload.
    module Tracker
      PAYLOAD_TARGET = "notice-bar-payload".freeze

      module_function

      def handle(event_name, payload)
        user = payload[:user]
        return if user.nil? || user.ai_user?

        # Only matching events reserve a later mission's backfill for its own
        # completion broadcast. Rejected payloads must not defer that backfill.
        candidates = open_candidates(event_name, user).select { |notice| notice.completed_by?(event_name, payload, user) }
        candidates.each_with_index do |notice, index|
          current = !notice.mission? || head_of_group?(notice, user)
          next unless current || notice.allow_early_completion

          next unless UserNotice.complete!(user, notice.key)

          broadcast(user, completed: current ? notice.key : nil, awaiting: candidates.drop(index + 1).map(&:key))
        end
      rescue StandardError => e
        # Progress tracking must never break the action that emitted the event.
        Rails.logger.error("[Notices::Tracker] #{event_name}: #{e.class}: #{e.message}")
      end

      # Notices listening to the event that this user has not finished yet.
      def open_candidates(event_name, user)
        candidates = NoticeRegistry.listening_to(event_name).select { |notice| notice.active? }
        return [] if candidates.empty?

        finished = UserNotice.where(user: user, notice_key: candidates.map { |notice| notice.key.to_s },
                                    status: %i[completed dismissed]).pluck(:notice_key)
        candidates.select { |notice| !finished.include?(notice.key.to_s) && notice.visible_to?(user) }
      end

      def broadcast(user, completed: nil, awaiting: [], changed: nil, refresh_at: nil)
        I18n.with_locale(locale_for(user)) do
          feed = Feed.new(user, awaiting: awaiting)
          Turbo::StreamsChannel.broadcast_replace_to(
            [ "inbox", user ],
            target: PAYLOAD_TARGET,
            partial: "collavre/notices/payload",
            locals: { items: feed.items, completion: completed && feed.completion(completed),
                      changed: changed, refresh_at: refresh_at }
          )
        end
      end

      def head_of_group?(notice, user)
        earlier = NoticeRegistry.group(notice.group).take_while { |member| member != notice }
        return true if earlier.empty?

        UserNotice.completed.where(user: user, notice_key: earlier.map { |member| member.key.to_s }).count == earlier.size
      end

      def locale_for(user)
        available = I18n.available_locales.map(&:to_s)
        user.locale.to_s.presence_in(available) || I18n.default_locale
      end
    end
  end
end
