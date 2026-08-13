module Collavre
  class UserCreativePreferencesController < ApplicationController
    MAX_LAST_TOPIC_SAVE_SESSIONS = 32

    def toggle
      creative_id = params[:creative_id]
      node_id = params[:node_id].to_s
      expanded = ActiveModel::Type::Boolean.new.cast(params[:expanded])

      with_preference(creative_id) do |record|
        state = record.expanded_status || {}

        if expanded
          state[node_id] = true
        else
          state.delete(node_id)
        end

        record.expanded_status = state
        if empty_preference?(record, state)
          record.destroy!
        else
          record.save!
        end
      end

      render json: { success: true }
    end

    def update_last_topic
      return issue_last_topic_save_fence if request.post?

      creative = Creative.find(params[:creative_id]).effective_origin

      return render_forbidden unless readable?(creative)
      return render_invalid_topic unless valid_last_topic?(creative)

      record, saved = persist_last_topic(creative)
      broadcast_last_topic(creative, record) if saved

      render json: {
        success: saved,
        stale_last_topic_save: !saved,
        last_topic_revision: [ record.id, record.last_topic_revision ]
      }
    end

    # Issue this before sending the PATCH so an older request that is still
    # running can never commit after a newer selection. The two counters are
    # deliberately global to this user/creative preference, rather than one
    # per controller session, so their storage stays bounded.
    def issue_last_topic_save_fence
      creative = Creative.find(params[:creative_id]).effective_origin

      return render_forbidden unless readable?(creative)

      fence = with_preference(creative.id) do |record|
        record.last_topic_save_fence_issued = [
          record.last_topic_save_fence_issued.to_i,
          record.last_topic_save_fence_applied.to_i
        ].max + 1
        record.save!
        record.last_topic_save_fence_issued
      end

      render json: { last_topic_save_fence: fence }
    end

    private

    def readable?(creative)
      creative.has_permission?(Current.user, :read) || creative.user == Current.user
    end

    def empty_preference?(record, state)
      state.empty? && record.last_topic_id.nil? && record.last_topic_revision.to_i.zero? &&
        record.last_topic_save_fence_issued.to_i.zero? && record.last_topic_save_fence_applied.to_i.zero?
    end

    def valid_last_topic?(creative)
      params[:last_topic_id].blank? || creative.topics.exists?(id: params[:last_topic_id])
    end

    def persist_last_topic(creative)
      with_preference(creative.id) do |record|
        if stale_last_topic_save?(record)
          next [ record, false ]
        end

        record.expanded_status ||= {}
        record.last_topic_id = params[:last_topic_id].presence
        record.last_topic_revision = record.last_topic_revision.to_i + 1
        assign_last_topic_save_order(record)
        # Retain a cleared preference after it has participated in last-topic
        # ordering. Its revision lets a reopened client distinguish a newer
        # Main selection from the empty snapshot that preceded an in-flight save.
        if empty_preference?(record, record.expanded_status)
          record.destroy!
        else
          record.save!
        end
        [ record, true ]
      end
    end

    # The client id carries a controller session, a monotonically increasing
    # sequence, and an echo nonce. Older clients still send arbitrary ids, so
    # only recognized ordering ids take this fencing path.
    def stale_last_topic_save?(record)
      fence = last_topic_save_fence
      if fence
        return true if fence > record.last_topic_save_fence_issued.to_i

        return record.last_topic_save_fence_applied.to_i >= fence
      end

      session_id, sequence = last_topic_save_order
      return false unless session_id.present?

      last_topic_save_sequences(record).fetch(session_id, 0).to_i >= sequence
    end

    def assign_last_topic_save_order(record)
      fence = last_topic_save_fence
      if fence
        record.last_topic_save_fence_applied = fence
        return
      end

      # A new client can reach an older instance for its POST and a newer one
      # for its fallback PATCH. That PATCH supersedes every fence issued before
      # it, so retire them before a delayed fenced save can overwrite it.
      if legacy_last_topic_save_fence_fallback?
        record.last_topic_save_fence_applied = record.last_topic_save_fence_issued.to_i
      end

      session_id, sequence = last_topic_save_order
      return unless session_id.present?

      sequences = last_topic_save_sequences(record)
      # Keep recent sessions in insertion order so a preference cannot retain
      # an unbounded history of tabs that have already gone away.
      sequences.delete(session_id)
      sequences[session_id] = sequence
      sequences.shift while sequences.size > MAX_LAST_TOPIC_SAVE_SESSIONS

      record.last_topic_save_sequences = sequences
      record.last_topic_save_session_id = session_id
      record.last_topic_save_sequence = sequence
    end

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
    def with_preference(creative_id)
      record = preference_for(creative_id)
      record.with_lock { yield record }
    rescue ActiveRecord::RecordNotFound
      retry
    end

    # Preserve the legacy single-session columns while a rolling deploy may
    # still have records written by the preceding application version.
    def last_topic_save_sequences(record)
      sequences = record.last_topic_save_sequences || {}
      legacy_session_id = record.last_topic_save_session_id
      return sequences unless legacy_session_id.present?

      legacy_sequence = record.last_topic_save_sequence.to_i
      sequences.merge(legacy_session_id => [ sequences.fetch(legacy_session_id, 0).to_i, legacy_sequence ].max)
    end

    def last_topic_save_order
      match = params[:client_id].to_s.match(/\A([A-Za-z0-9-]+)\.([1-9]\d*)\.[A-Za-z0-9-]+\z/)
      return [ nil, nil ] unless match

      [ match[1], match[2].to_i ]
    end

    def last_topic_save_fence
      value = params[:last_topic_save_fence].to_s
      return unless value.match?(/\A[1-9]\d*\z/)

      value.to_i
    end

    def legacy_last_topic_save_fence_fallback?
      ActiveModel::Type::Boolean.new.cast(params[:legacy_last_topic_save_fence_fallback])
    end

    def broadcast_last_topic(creative, record)
      payload = {
        action: "last_topic_changed",
        last_topic_id: record.last_topic_id,
        last_topic_revision: [ record.id, record.last_topic_revision ],
        client_id: params[:client_id].presence
      }
      TopicsChannel.broadcast_to("user_#{Current.user.id}_creative_#{creative.id}", payload)
    end

    def render_forbidden
      render json: { error: I18n.t("collavre.user_creative_preferences.no_permission") }, status: :forbidden
    end

    def render_invalid_topic
      render json: { error: I18n.t("collavre.user_creative_preferences.invalid_topic") }, status: :unprocessable_entity
    end
  end
end
