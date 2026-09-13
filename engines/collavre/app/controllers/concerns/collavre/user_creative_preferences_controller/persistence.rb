module Collavre
  module UserCreativePreferencesController::Persistence
    extend ActiveSupport::Concern

    # A concurrent collapse can delete the row between the lookup and the lock.
    # Retrying twice covers that race; beyond it the row is not coming back.
    MAX_PREFERENCE_LOCK_ATTEMPTS = 3

    private

    # insert_all uses the unique preference key as the first-insert fence.
    # A row lock alone cannot serialize two requests that both see no row.
    def preference_for(creative_id)
      now = Time.current
      attributes = { creative_id: creative_id, user_id: Current.user.id, expanded_status: {}, created_at: now, updated_at: now }
      insert_preference(attributes)
      UserCreativePreference.find_by!(creative_id: creative_id, user_id: Current.user.id)
    end

    def insert_preference(attributes)
      UserCreativePreference.transaction(requires_new: true) do
        UserCreativePreference.insert_all([ attributes ], unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
      end
    rescue ActiveRecord::InvalidForeignKey
      # Only the initial insert is covered, after its savepoint has rolled back.
      # Check the actual origin id being written, not the linked request id.
      Creative.find(attributes[:creative_id]) if attributes[:creative_id].present?
      raise
    end

    # A collapse can remove an empty row after it is found but before with_lock
    # reloads it. Reacquire by the unique preference key so every save path
    # shares the same first-insert and deletion-race handling.
    #
    # Only the lookup/lock window is retried, and only a bounded number of
    # times: once the row is locked the block owns the transaction, so a
    # RecordNotFound it raises itself must propagate rather than replay the
    # block, and a row that keeps vanishing must surface instead of spinning.
    def with_preference(creative_id)
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
