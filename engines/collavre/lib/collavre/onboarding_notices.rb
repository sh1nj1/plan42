# frozen_string_literal: true

module Collavre
  # The first-run onboarding missions shown in the notice bar, in step order.
  # Each one points at the UI element that does the task (:target) and finishes
  # from the domain event that task emits (:completes_on). done_when only backfills
  # users who did the task before the mission reached them.
  module OnboardingNotices
    CREATIVE_CREATED = "creative_created.collavre"
    COMMENT_CREATED = "comment_created.collavre"

    module_function

    def register
      NoticeRegistry.register(:onboarding_first_creative,
        kind: :mission, group: :onboarding, icon: "🌱",
        target: ".new-root-creative-btn, .add-creative-btn",
        cta_path: ->(routes, _user) { routes.creatives_path },
        done_when: ->(user) { creative_created?(user) },
        completes_on: { CREATIVE_CREATED => ->(payload) { !payload[:creative].inbox? } })

      NoticeRegistry.register(:onboarding_sub_creative,
        kind: :mission, group: :onboarding, icon: "🌿",
        target: ".add-creative-btn",
        cta_path: method(:latest_creative_path),
        done_when: ->(user) { creative_created?(user, child: true) },
        completes_on: { CREATIVE_CREATED => ->(payload) { payload[:creative].parent_id.present? } })

      NoticeRegistry.register(:onboarding_call_agent,
        kind: :mission, group: :onboarding, icon: "🌳",
        target: "[data-comments--form-target='textarea']",
        audience: method(:agent_available?),
        allow_early_completion: true,
        cta_path: ->(routes, user) { latest_creative_path(routes, user, open_comments: true) },
        done_when: method(:agent_called?),
        completes_on: { COMMENT_CREATED => ->(payload) { payload[:comment].mentioned_users.ai_agents.exists? } })
    end

    def own_creatives(user)
      Creative.where(user: user).where.not(id: Creative.inboxes.select(:id))
    end

    # Shared children inherit their parent's owner. Applied history retains the
    # actual creator; ownership remains a fallback for records predating history.
    def creative_created?(user, child: false)
      owned = own_creatives(user)
      owned = owned.where.not(parent_id: nil) if child
      return true if owned.exists?

      changes = CreativeChange.joins(:change_set).where(operation: "create")
        .where(creative_change_sets: { user_id: user.id, status: "applied", actor_kind: "human" })
        .where(creative_id: Creative.where.not(id: Creative.inboxes.select(:id)).select(:id))
      changes = changes.where("creative_changes.after ->> 'parent_id' IS NOT NULL") if child
      changes.exists?
    end

    # The creative the user touched last is where the next step happens. A
    # collaborator who only works in someone else's tree owns no root, so fall
    # back to the last creative they visited and may comment on.
    def latest_creative_path(routes, user, **options)
      creative = latest_creative(user)
      creative ? routes.creative_path(creative, **options) : routes.creatives_path
    end

    def latest_creative(user)
      own_creatives(user).where(parent_id: nil, origin_id: nil).order(id: :desc).first || commentable_last_visit(user)
    end

    # Match the composer destination and its mention resolver, without depending
    # on a vendor engine. Availability can change after onboarding has started.
    def agent_available?(user)
      !user.ai_user? && Collavre.user_class.mentionable_for(latest_creative(user)).ai_agents.exists?
    end

    def commentable_last_visit(user)
      creative = user.last_visited_creative
      creative if creative&.has_permission?(user, :feedback)
    end

    # Use the same mention resolver as live completion, including shared trees.
    # This one-time backfill must not depend on an asynchronous agent reply.
    def agent_called?(user)
      Comment.where(user: user).where("content LIKE ?", "%@%").includes(:user, :creative)
             .find_each.any? { |comment| comment.mentioned_users.ai_agents.exists? }
    end
  end
end
