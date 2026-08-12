module Collavre
  class CreativeShare < ApplicationRecord
    self.table_name = "creative_shares"

    belongs_to :creative, class_name: "Collavre::Creative"
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :shared_by, class_name: Collavre.configuration.user_class_name, optional: true

    enum :permission, {
      no_access: 0,
      read: 1,
      feedback: 2,
      write: 3,
      admin: 4
    }

    validates :creative_id, presence: true
    validates :user_id, presence: true, unless: -> { user_id.nil? } # Public share has nil user_id

    validates :permission, presence: true
    validates :user_id, uniqueness: { scope: :creative_id }, allow_nil: true

    # Single declarative registry mirroring Creative::Permissible: which
    # persisted CreativeShare attributes affect the permission cache, and how.
    # Every create and update re-propagates the share unconditionally (see
    # dispatch_share_cache_invalidation) — a fail-closed refresh that matches
    # the prior propagate_cache and survives a multi-save transaction clobbering
    # an earlier permission change out of the final saved_changes. This map
    # governs the *extra* cleanup a move or reassignment needs on top of that
    # base refresh, so a new share-mutation path still can't silently skip it:
    #
    #   :relocate    -> creative_id moved: purge this share's rows and rebuild
    #                   the vacated (old creative, old user) subtree
    #   :reassign    -> user_id changed: purge this share's rows and rebuild the
    #                   old user's subtree at the current creative
    #   :repropagate -> permission changed: covered by the unconditional
    #                   re-propagate above (listed to document the invariant)
    PERMISSION_INVALIDATING_ATTRIBUTES = {
      "creative_id" => :relocate,
      "user_id"     => :reassign,
      "permission"  => :repropagate
    }.freeze

    after_create_commit :notify_recipient, unless: :no_access?
    after_save :touch_creative_subtree
    after_destroy :touch_creative_subtree

    after_commit :dispatch_share_cache_invalidation, on: [ :create, :update ]
    after_create :reconcile_stranded_topic_read_pointers
    after_update :reconcile_stranded_topic_read_pointers, if: :access_granted?
    after_destroy :reconcile_stranded_topic_read_pointers
    after_commit :broadcast_share_change, on: [ :create, :update ]
    after_destroy_commit :remove_cache
    after_destroy_commit :broadcast_share_destroy

    # Given ancestor_ids and ancestor_shares, returns the closest CreativeShare
    # in the ancestors. If there is no ancestor share, returns nil.
    def self.closest_parent_share(ancestor_ids, ancestor_shares)
      ancestor_shares.to_a.min_by { |s| ancestor_ids.index(s.creative_id) || Float::INFINITY }
    end

    def sharer_id
      shared_by_id || creative.user_id
    end

    private

    def touch_creative_subtree
      creatives_to_touch = []

      # Current creative
      creatives_to_touch << creative if creative

      # Old creative if changed (check before_last_save because we are in after_save)
      if saved_change_to_creative_id?
        old_id = creative_id_before_last_save
        if old_id && old_id != creative_id
          creatives_to_touch << Creative.find_by(id: old_id)
        end
      end

      creatives_to_touch.compact.uniq.each do |c|
        timestamp = Time.current
        c.touch
        c.descendants.update_all(updated_at: timestamp)
      end
    end

    def notify_recipient
      return unless Current.user && user
      return if user.ai_user?
      inbox_creative = Creative.inbox_for(user)
      short_title = Collavre::HtmlText.markdown_label(creative.effective_description, 30)
      creative_path = Collavre::Engine.routes.url_helpers.creative_path(creative, open_comments: true)
      creative_link = "[#{short_title}](#{creative_path})"
      msg = I18n.t(
        "inbox.creative_shared",
        user: Current.user.display_name,
        short_title: creative_link,
        locale: user.locale || "en"
      )
      system_topic = inbox_creative.system_topic(fallback_user: user)
      Comment.create!(
        creative: inbox_creative,
        topic: system_topic,
        content: msg,
        user: nil,
        skip_default_user: true
      )
    end

    def linked_creative_exists?
      Creative.exists?(origin_id: creative.id, user_id: user.id)
    end

    # Single dispatch point for permission-cache invalidation on share writes.
    # Every create and update re-propagates the share unconditionally — a
    # fail-closed refresh matching the prior propagate_cache, correct even when
    # a multi-save transaction clobbers an earlier permission change out of the
    # final saved_changes. On an update, a move (creative_id) or reassignment
    # (user_id) additionally purges the stale rows this share left behind — the
    # purge is carried on the same propagate_share job (purge_stale:) rather than
    # deleted synchronously, so timing is uniform and it no longer blocks commit.
    def dispatch_share_cache_invalidation
      propagate_args = { creative_share_id: id }

      unless previously_new_record?
        operations = (saved_changes.keys & PERMISSION_INVALIDATING_ATTRIBUTES.keys)
          .map { |attr| PERMISSION_INVALIDATING_ATTRIBUTES[attr] }
          .uniq

        # A move (creative_id) or reassignment (user_id) leaves stale rows keyed
        # to this share. The purge rides ON the propagate_share job (purge_stale:
        # true), which deletes those rows immediately before re-propagating — in
        # one job, never as a standalone enqueue. The authz queue runs two
        # threads, so a separate purge could otherwise run AFTER propagate and
        # delete the freshly written rows (both key on source_share_id), dropping
        # the share's access until an unrelated rebuild. Folding it in keeps the
        # work async (off the commit path) so the revoke of the vacated access is
        # merely deferred by the queue latency (~1-2s) — it only PROLONGS an
        # already-granted permission by that window, never grants a new one,
        # which the CTO judged acceptable for the perf win. Then rebuild the
        # vacated subtree. creative_id takes precedence when both change,
        # preserving the prior branch order.
        if operations.include?(:relocate) || operations.include?(:reassign)
          propagate_args[:purge_stale] = true
          rebuild_vacated_subtree(relocated: operations.include?(:relocate))
        end
      end

      PermissionCacheJob.perform_later(:propagate_share, **propagate_args)
    end

    # Rebuild the cache the moved/reassigned share vacated, for the old user in
    # the old location, so an ancestor share (or its absence) is re-applied.
    def rebuild_vacated_subtree(relocated:)
      if relocated
        old_creative_id = creative_id_before_last_save
        old_user_id = user_id_before_last_save || user_id
        return unless old_creative_id

        PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
          creative_id: old_creative_id,
          user_id: old_user_id
        )
      else
        old_user_id = user_id_before_last_save
        return unless old_user_id

        PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
          creative_id: creative_id,
          user_id: old_user_id
        )
      end
    end

    def remove_cache
      # Capture IDs before destroy (after_destroy still has access to attributes)
      PermissionCacheJob.perform_later(:remove_share,
        creative_share_id: id,
        creative_id: creative_id,
        user_id: user_id
      )
    end

    def broadcast_share_change
      previous_permission = saved_change_to_permission? ? permission_before_last_save : nil

      CommentsPresenceChannel.broadcast_shares_changed(
        creative.effective_origin.id,
        shared_user_id: user_id,
        permission: permission,
        action: previously_new_record? ? "created" : "updated",
        has_access: permission_allows_access?(permission),
        can_comment: permission_allows_comment?(permission),
        has_access_changed: permission_allows_access?(previous_permission) != permission_allows_access?(permission),
        can_comment_changed: permission_allows_comment?(previous_permission) != permission_allows_comment?(permission)
      )
    end

    def broadcast_share_destroy
      previous_permission = permission

      CommentsPresenceChannel.broadcast_shares_changed(
        creative.effective_origin.id,
        shared_user_id: user_id,
        permission: nil,
        action: "destroyed",
        has_access: false,
        can_comment: false,
        has_access_changed: permission_allows_access?(previous_permission),
        can_comment_changed: permission_allows_comment?(previous_permission)
      )
    end

    # A topic can be moved before one of its source readers is shared on the
    # destination. The move deliberately leaves that reader's pointer on the
    # source to avoid exposing it there. Once access is granted (including when
    # a no_access override is removed), restore the pointer to the topic's
    # current creative so its read history follows it.
    def reconcile_stranded_topic_read_pointers
      destination = creative.effective_origin
      return unless destination.all_shared_users(:read).any? { |share| share.user_id == user_id }

      CommentReadPointer.joins(:topic)
        .where(user_id: user_id, topics: { creative_id: destination.id })
        .where.not(creative_id: destination.id)
        .find_each do |pointer|
          pointer.update_column(:creative_id, destination.id)
        end
    end

    def access_granted?
      return false unless user_id && permission_allows_access?(permission)

      previously_new_record? || saved_change_to_user_id? ||
        (saved_change_to_permission? && !permission_allows_access?(permission_before_last_save))
    end

    def permission_allows_access?(value)
      value.present? && value != "no_access"
    end

    def permission_allows_comment?(value)
      value.present? && CreativeShare.permissions[value] >= CreativeShare.permissions["feedback"]
    end
  end
end
