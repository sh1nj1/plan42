module Collavre
  module Notices
    # Builds the ordered list of notices a user should see in the notice bar,
    # already translated for the current locale.
    #
    # A mission's done_when check runs once, the first time the mission reaches
    # the head of its group, so users who already did the task skip it. After
    # that the mission waits for its completion event (see Notices::Tracker),
    # which keeps page loads free of per-request progress queries.
    class Feed
      def initialize(user, routes: Collavre::Engine.routes.url_helpers, now: Time.current)
        @user = user
        @routes = routes
        @now = now
      end

      def items
        return [] unless @user

        visible = NoticeRegistry.all.each_with_index.filter_map do |notice, index|
          next unless showable?(notice)

          [ notice, index ]
        end
        visible.sort_by { |notice, index| [ notice.priority, index ] }.map { |notice, _| serialize(notice) }
      end

      # The celebration copy for a mission that was just completed, including
      # what comes next in its group (nil when the group is finished).
      def completion(key)
        notice = NoticeRegistry.find(key)
        return unless notice

        following = notice.group && NoticeRegistry.group(notice.group).find { |member| showable?(member) }
        {
          key: notice.key.to_s,
          done: translate(notice, :done) || I18n.t("collavre.notices.bar.completed"),
          next_key: following&.key&.to_s
        }
      end

      private

      def states
        @states ||= UserNotice.where(user: @user).index_by(&:notice_key)
      end

      def state_for(notice)
        states[notice.key.to_s]
      end

      def showable?(notice)
        return false unless notice.active?(@now) && notice.visible_to?(@user)
        return false if state_for(notice)&.hidden?(@now)
        return true unless notice.mission?

        head_of_group?(notice) && !backfill_completed?(notice)
      end

      # Missions in a group run one at a time, in registration order.
      def head_of_group?(notice)
        NoticeRegistry.group(notice.group).take_while { |member| member != notice }
                      .all? { |member| state_for(member)&.completed? }
      end

      def backfill_completed?(notice)
        return false if state_for(notice)

        status = notice.done_for?(@user) ? :completed : :pending
        states[notice.key.to_s] = UserNotice.record!(@user, notice.key, status)
        status == :completed
      end

      def serialize(notice)
        {
          key: notice.key.to_s,
          kind: notice.kind.to_s,
          icon: notice.icon,
          tag: tag_for(notice),
          title: translate(notice, :title),
          summary: translate(notice, :summary),
          body: translate(notice, :body),
          cta: translate(notice, :cta) || I18n.t("collavre.notices.bar.ok"),
          cta_url: notice.cta_path(@routes, @user),
          target: notice.target,
          tip: translate(notice, :tip),
          done: translate(notice, :done),
          steps: notice.mission? ? steps_for(notice) : nil
        }.compact
      end

      def tag_for(notice)
        return I18n.t("collavre.notices.kinds.#{notice.kind}") unless notice.mission?

        members = NoticeRegistry.group(notice.group)
        I18n.t("collavre.notices.groups.#{notice.group}", step: members.index(notice) + 1, total: members.size)
      end

      def steps_for(notice)
        NoticeRegistry.group(notice.group).map do |member|
          state = if member == notice then "current"
          elsif state_for(member)&.completed? then "done"
          else "todo"
          end
          { title: translate(member, :title), state: state }
        end
      end

      def translate(notice, field)
        I18n.t("#{notice.i18n_scope}.#{field}", default: nil)
      end
    end
  end
end
