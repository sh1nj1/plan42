module Collavre
  class CreativeExpandedStatesController < ApplicationController
    def toggle
      creative_id = params[:creative_id]
      node_id = params[:node_id].to_s
      expanded = ActiveModel::Type::Boolean.new.cast(params[:expanded])

      record = CreativeExpandedState.find_or_initialize_by(creative_id: creative_id, user_id: Current.user.id)
      state = record.expanded_status || {}

      if expanded
        state[node_id] = true
      else
        state.delete(node_id)
      end

      record.expanded_status = state
      if state.empty?
        record.destroy if record.persisted?
      else
        record.save!
      end

      render json: { success: true }
    end
  end
end
