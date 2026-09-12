module Collavre
  module UserCreativePreferencesController::Persistence
    extend ActiveSupport::Concern

    # A concurrent collapse can delete the row between the lookup and the lock.
    # Retrying twice covers that race; beyond it the row is not coming back.
    MAX_PREFERENCE_LOCK_ATTEMPTS = 3

    included do
      rescue_from ActiveRecord::InvalidForeignKey, with: :handle_deleted_preference_creative
    end

    private

    # insert_all uses the unique preference key as the first-insert fence.
    # A row lock alone cannot serialize two requests that both see no row.
    def preference_for(creative_id)
      now = Time.current
      attributes = { creative_id: creative_id, user_id: Current.user.id, expanded_status: {}, created_at: now, updated_at: now }
      UserCreativePreference.insert_all([ attributes ], unique_by: :index_user_creative_preferences_on_creative_id_and_user_id)
      UserCreativePreference.find_by!(creative_id: creative_id, user_id: Current.user.id)
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

    # Run after the failed save transaction has unwound, so PostgreSQL can
    # query again. A delayed browser save for a deleted creative is a 404;
    # violations involving a live creative must still surface as errors.
    def handle_deleted_preference_creative(error)
      raise error if params[:creative_id].blank? || Creative.exists?(params[:creative_id])

      head :not_found
    end
  end
end
