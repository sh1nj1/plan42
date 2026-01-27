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

    after_create_commit :notify_recipient, unless: :no_access?
    after_save :touch_creative_subtree
    after_destroy :touch_creative_subtree

    after_commit :propagate_cache, on: [ :create, :update ]
    after_destroy_commit :remove_cache

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
      desc = creative.effective_description
      title = ActionController::Base.helpers.strip_tags(desc)
      short_title = ActionController::Base.helpers.truncate(title, length: 30)
      InboxItem.create!(
        owner: user,
        message_key: "inbox.creative_shared",
        message_params: { user: Current.user.display_name, short_title: short_title },
        link: Collavre::Engine.routes.url_helpers.creative_url(
          creative,
          Rails.application.config.action_mailer.default_url_options
        )
      )
    end

    def linked_creative_exists?
      Creative.exists?(origin_id: creative.id, user_id: user.id)
    end

    def propagate_cache
      # If creative_id or user_id changed, handle old cache entries properly
      if saved_change_to_creative_id? || saved_change_to_user_id?
        # Delete only caches created by THIS share (fast operation, keep synchronous)
        CreativeSharesCache.where(source_share_id: id).delete_all

        # Rebuild caches for old user in old subtree (background job)
        if saved_change_to_creative_id?
          old_creative_id = creative_id_before_last_save
          old_user_id = user_id_before_last_save || user_id
          if old_creative_id
            PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
              creative_id: old_creative_id,
              user_id: old_user_id
            )
          end
        elsif saved_change_to_user_id?
          old_user_id = user_id_before_last_save
          if old_user_id
            PermissionCacheJob.perform_later(:rebuild_user_cache_for_subtree,
              creative_id: creative_id,
              user_id: old_user_id
            )
          end
        end
      end

      PermissionCacheJob.perform_later(:propagate_share, creative_share_id: id)
    end

    def remove_cache
      # Capture IDs before destroy (after_destroy still has access to attributes)
      PermissionCacheJob.perform_later(:remove_share,
        creative_share_id: id,
        creative_id: creative_id,
        user_id: user_id
      )
    end
  end
end
