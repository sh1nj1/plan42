module Collavre
  class UserCreativePreferencesController < ApplicationController
    def toggle
      creative_id = params[:creative_id]
      node_id = params[:node_id].to_s
      expanded = ActiveModel::Type::Boolean.new.cast(params[:expanded])

      record = UserCreativePreference.find_or_initialize_by(creative_id: creative_id, user_id: Current.user.id)
      state = record.expanded_status || {}

      if expanded
        state[node_id] = true
      else
        state.delete(node_id)
      end

      record.expanded_status = state
      if state.empty? && record.last_topic_id.nil? && record.last_topic_revision.to_i.zero?
        record.destroy if record.persisted?
      else
        record.save!
      end

      render json: { success: true }
    end

    def update_last_topic
      creative = Creative.find(params[:creative_id]).effective_origin

      return render_forbidden unless readable?(creative)
      return render_invalid_topic unless valid_last_topic?(creative)

      record = persist_last_topic(creative)
      broadcast_last_topic(creative, record)

      render json: { success: true, last_topic_revision: [ record.id, record.last_topic_revision ] }
    end

    private

    def readable?(creative)
      creative.has_permission?(Current.user, :read) || creative.user == Current.user
    end

    def valid_last_topic?(creative)
      params[:last_topic_id].blank? || creative.topics.exists?(id: params[:last_topic_id])
    end

    def persist_last_topic(creative)
      record = UserCreativePreference.find_or_initialize_by(creative_id: creative.id, user_id: Current.user.id)
      record.with_lock do
        record.expanded_status ||= {}
        record.last_topic_id = params[:last_topic_id].presence
        record.last_topic_revision = record.last_topic_revision.to_i + 1
        # Retain a cleared preference after it has participated in last-topic
        # ordering. Its revision lets a reopened client distinguish a newer
        # Main selection from the empty snapshot that preceded an in-flight save.
        if record.expanded_status.empty? && record.last_topic_id.nil? && record.last_topic_revision.zero?
          record.destroy!
        else
          record.save!
        end
      end
      record
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
