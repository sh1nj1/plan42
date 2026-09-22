module Collavre
  module UserCreativePreferencesController::Persistence
    extend ActiveSupport::Concern

    # A concurrent collapse can delete the row between the lookup and the lock.
    # Retrying twice covers that race; beyond it the row is not coming back.
    MAX_PREFERENCE_LOCK_ATTEMPTS = 3

    private

    # Keep bounded watermarks on the user, independently of disposable
    # preferences. The same transaction commits both the fence and the toggle.
    def with_expansion_order
      user = Current.user.class.find(Current.user.id)
      user.with_lock do
        order = Creatives::ExpansionSaveOrder.new(user.expansion_save_sequences)
        result = yield order
        user.update_columns(expansion_save_sequences: order.state)
        result
      end
    end

    # insert_all uses the unique preference key as the first-insert fence.
    # Root inserts instead rely on the user lock held by with_preference.
    def preference_for(creative_id)
      now = Time.current
      attributes = { creative_id: creative_id, user_id: Current.user.id, expanded_status: {}, created_at: now, updated_at: now }
      insert_preference(attributes)
      UserCreativePreference.find_by!(creative_id: creative_id, user_id: Current.user.id)
    end

    def insert_preference(attributes)
      return if attributes[:creative_id].nil? && UserCreativePreference.exists?(user_id: attributes[:user_id], creative_id: nil)

      UserCreativePreference.transaction(requires_new: true) do
        UserCreativePreference.insert_all([ attributes ])
      end
    rescue ActiveRecord::InvalidForeignKey
      # Only the initial insert is covered, after its savepoint has rolled back.
      # Check the actual origin id being written, not the linked request id.
      Creative.find(attributes[:creative_id]) if attributes[:creative_id].present?
      raise
    end

    def with_preference(creative_id, &block)
      return with_locked_preference(creative_id, &block) if creative_id.present?

      # Fence missing root rows without a new constraint that breaks old images.
      Current.user.class.find(Current.user.id).with_lock do
        consolidate_root_preferences
        with_locked_preference(nil, &block)
      end
    end

    def consolidate_root_preferences
      # Legacy writers do not take the user lock. Lock each observed row before
      # reading its state, and never delete a later insert we have not merged.
      roots = UserCreativePreference.where(user_id: Current.user.id, creative_id: nil).order(:id).lock.to_a
      return if roots.size < 2

      state = roots.each_with_object({}) { |record, merged| merged.merge!(record.expanded_status || {}) }
      roots.first.update_columns(expanded_status: state)
      UserCreativePreference.where(id: roots.drop(1).map(&:id)).delete_all
    end

    # A collapse can remove an empty row after it is found but before with_lock
    # reloads it. Reacquire by the unique preference key so every save path
    # shares the same first-insert and deletion-race handling.
    #
    # Only the lookup/lock window is retried, and only a bounded number of
    # times: once the row is locked the block owns the transaction, so a
    # RecordNotFound it raises itself must propagate rather than replay the
    # block, and a row that keeps vanishing must surface instead of spinning.
    def with_locked_preference(creative_id)
      attempts = 0
      locked = false

      begin
        record = preference_for(creative_id)
        record.with_lock do
          locked = true
          yield record
        end
      rescue ActiveRecord::RecordNotFound
        raise if locked

        attempts += 1
        raise if attempts >= MAX_PREFERENCE_LOCK_ATTEMPTS

        retry
      end
    end
  end
end
