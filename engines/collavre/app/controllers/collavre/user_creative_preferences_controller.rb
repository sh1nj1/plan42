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
      if state.empty? && record.last_topic_id.nil?
        record.destroy if record.persisted?
      else
        record.save!
      end

      render json: { success: true }
    end

    def update_last_topic
      creative = Creative.find(params[:creative_id]).effective_origin

      unless creative.has_permission?(Current.user, :read) || creative.user == Current.user
        render json: { error: I18n.t("collavre.user_creative_preferences.no_permission") }, status: :forbidden and return
      end

      # Validate that the topic belongs to this creative
      if params[:last_topic_id].present?
        unless creative.topics.exists?(id: params[:last_topic_id])
          render json: { error: I18n.t("collavre.user_creative_preferences.invalid_topic") }, status: :unprocessable_entity and return
        end
      end

      record = UserCreativePreference.find_or_initialize_by(creative_id: creative.id, user_id: Current.user.id)
      record.expanded_status ||= {}
      record.last_topic_id = params[:last_topic_id].presence

      if record.expanded_status.empty? && record.last_topic_id.nil?
        record.destroy if record.persisted?
      else
        record.save!
      end

      # Broadcast only to the current user's sessions (not all creative subscribers)
      TopicsChannel.broadcast_to(
        "user_#{Current.user.id}_creative_#{creative.id}",
        { action: "last_topic_changed", last_topic_id: record.last_topic_id }
      )

      render json: { success: true }
    end
  end
end
