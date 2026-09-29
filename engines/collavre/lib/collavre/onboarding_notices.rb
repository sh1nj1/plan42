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
        done_when: ->(user) { own_creatives(user).exists? },
        completes_on: { CREATIVE_CREATED => ->(payload) { !payload[:creative].inbox? } })

      NoticeRegistry.register(:onboarding_sub_creative,
        kind: :mission, group: :onboarding, icon: "🌿",
        target: ".add-creative-btn",
        cta_path: method(:latest_creative_path),
        done_when: ->(user) { own_creatives(user).where.not(parent_id: nil).exists? },
        completes_on: { CREATIVE_CREATED => ->(payload) { payload[:creative].parent_id.present? } })

      NoticeRegistry.register(:onboarding_call_agent,
        kind: :mission, group: :onboarding, icon: "🌳",
        target: "[data-comments--form-target='textarea']",
        cta_path: method(:latest_creative_path),
        done_when: method(:agent_replied_in_own_creative?),
        completes_on: { COMMENT_CREATED => ->(payload) { payload[:comment].mentioned_users.ai_agents.exists? } })
    end

    def own_creatives(user)
      Creative.where(user: user).where.not(id: Creative.inboxes.select(:id))
    end

    # The creative the user touched last is where the next step happens.
    def latest_creative_path(routes, user)
      creative = own_creatives(user).where(parent_id: nil, origin_id: nil).order(id: :desc).first
      creative ? routes.creative_path(creative) : routes.creatives_path
    end

    # Backfill proxy for "has called an agent": an agent has answered in one of
    # the user's own creatives. Both lookups are indexed, unlike scanning the
    # user's comments for mentions.
    def agent_replied_in_own_creative?(user)
      Comment.where(creative_id: own_creatives(user).select(:id),
                    user_id: Collavre.user_class.ai_agents.select(:id)).exists?
    end
  end
end
