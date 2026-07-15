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
    # persisted CreativeShare attributes invalidate the permission cache, and
    # how. A single after_commit dispatcher intersects saved_changes.keys with
    # this map so a new share-mutation path can never silently skip a required
    # cache rebuild. propagate_share is a pure function of these three columns,
    # so a change touching none of them leaves the cache untouched.
    #
    #   :relocate    -> creative_id moved: purge this share's rows and rebuild
    #                   the vacated (old creative, old user) subtree
    #   :reassign    -> user_id changed: purge this share's rows and rebuild the
    #                   old user's subtree at the current creative
    #   :repropagate -> permission changed: re-propagate in place
    #
    # Every tracked update then re-propagates the share into its subtree.
    PERMISSION_INVALIDATING_ATTRIBUTES = {
      "creative_id" => :relocate,
      "user_id"     => :reassign,
      "permission"  => :repropagate
    }.freeze

    after_create_commit :notify_recipient, unless: :no_access?
    after_save :touch_creative_subtree
    after_destroy :touch_creative_subtree

    after_commit :dispatch_share_cache_invalidation, on: [ :create, :update ]
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
      short_title = ActionController::Base.helpers.truncate(
        ActionController::Base.helpers.strip_tags(creative.effective_description),
        length: 30
      )
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
    # On create there is no prior location to reconcile, so the share is simply
    # propagated. On update, the attributes that actually changed are
    # intersected with PERMISSION_INVALIDATING_ATTRIBUTES; a change to none of
    # them leaves the cache untouched.
    def dispatch_share_cache_invalidation
      if previously_new_record?
        PermissionCacheJob.perform_later(:propagate_share, creative_share_id: id)
        return
      end

      operations = (saved_changes.keys & PERMISSION_INVALIDATING_ATTRIBUTES.keys)
        .map { |attr| PERMISSION_INVALIDATING_ATTRIBUTES[attr] }
        .uniq
      return if operations.empty?

      # A move (creative_id) or reassignment (user_id) leaves stale rows keyed
      # to this share. Purge them synchronously — a prompt, fail-closed revoke
      # of the vacated access — then rebuild the vacated subtree. creative_id
      # takes precedence when both change, preserving the prior branch order.
      if operations.include?(:relocate) || operations.include?(:reassign)
        CreativeSharesCache.where(source_share_id: id).delete_all
        rebuild_vacated_subtree(relocated: operations.include?(:relocate))
      end

      PermissionCacheJob.perform_later(:propagate_share, creative_share_id: id)
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

    def permission_allows_access?(value)
      value.present? && value != "no_access"
    end

    def permission_allows_comment?(value)
      value.present? && CreativeShare.permissions[value] >= CreativeShare.permissions["feedback"]
    end
  end
end
