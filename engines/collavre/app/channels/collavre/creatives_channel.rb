module Collavre
  class CreativesChannel < ApplicationCable::Channel
    def subscribed
      return reject unless params[:root_id].present? && current_user

      @root = Creative.find_by(id: params[:root_id])&.effective_origin
      return reject unless @root
      return reject unless @root.has_permission?(current_user, :read)

      stream_for @root
      CreativePresenceStore.add(@root.id, current_user.id)
      broadcast_presence
    end

    def unsubscribed
      if @root && current_user
        CreativePresenceStore.remove(@root.id, current_user.id)
        broadcast_presence
      end
    end

    def editing(data)
      return unless @root && current_user

      creative_id = data["creative_id"].to_i
      CreativesChannel.broadcast_to(@root, {
        editing: {
          creative_id: creative_id,
          user_id: current_user.id,
          user_name: current_user.display_name
        }
      })
    end

    def stopped_editing(data)
      return unless @root && current_user

      creative_id = data["creative_id"].to_i
      CreativesChannel.broadcast_to(@root, {
        stopped_editing: {
          creative_id: creative_id,
          user_id: current_user.id
        }
      })
    end

    private

    def broadcast_presence
      user_ids = CreativePresenceStore.list(@root.id)
      CreativesChannel.broadcast_to(@root, { presence: { user_ids: user_ids } })
    end
  end
end
