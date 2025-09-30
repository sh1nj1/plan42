class CreativeShare < ApplicationRecord
  belongs_to :creative
  belongs_to :user

  enum :permission, {
    no_access: 0,
    read: 1,
    feedback: 2,
    write: 3,
    admin: 4
  }

  validates :creative_id, presence: true
  validates :user_id, presence: true
  validates :permission, presence: true
  validates :user_id, uniqueness: { scope: :creative_id }

  after_create_commit :notify_recipient, unless: :no_access?
  after_save :clear_permission_cache
  after_destroy :clear_permission_cache

  # Given ancestor_ids and ancestor_shares, returns the closest CreativeShare
  # in the ancestors. If there is no ancestor share, returns nil.
  def self.closest_parent_share(ancestor_ids, ancestor_shares)
    ancestor_shares.to_a.min_by { |s| ancestor_ids.index(s.creative_id) || Float::INFINITY }
  end

  private

  def clear_permission_cache
    permission_levels = [ :read, :feedback, :write, :admin ]

    # Get current and previous values for creative_id and user_id
    current_creative_id = creative_id
    current_user_id = user_id
    previous_creative_id = saved_change_to_creative_id? ? creative_id_before_last_save : creative_id
    previous_user_id = saved_change_to_user_id? ? user_id_before_last_save : user_id

    # Collect all creative_id/user_id combinations that need cache clearing
    combinations_to_clear = []

    # Always clear current combination
    if current_creative_id && current_user_id
      combinations_to_clear << [ current_creative_id, current_user_id ]
    end

    # Clear previous combination if it's different (handles creative_id or user_id changes)
    if previous_creative_id && previous_user_id &&
       (previous_creative_id != current_creative_id || previous_user_id != current_user_id)
      combinations_to_clear << [ previous_creative_id, previous_user_id ]
    end

    # Clear cache for all combinations
    combinations_to_clear.each do |creative_id_val, user_id_val|
      # Clear for the creative itself
      permission_levels.each do |level|
        Rails.cache.delete("creative_permission:#{creative_id_val}:#{user_id_val}:#{level}")
      end

      # Clear for all descendants of this creative
      begin
        creative_record = Creative.find(creative_id_val)
        creative_record.self_and_descendants.pluck(:id).each do |descendant_id|
          permission_levels.each do |level|
            Rails.cache.delete("creative_permission:#{descendant_id}:#{user_id_val}:#{level}")
          end
        end
      rescue ActiveRecord::RecordNotFound
        # Creative might have been deleted, skip descendant clearing
      end
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
      link: Rails.application.routes.url_helpers.creative_url(
        creative,
        Rails.application.config.action_mailer.default_url_options
      )
    )
  end

  def linked_creative_exists?
    Creative.exists?(origin_id: creative.id, user_id: user.id)
  end
end
