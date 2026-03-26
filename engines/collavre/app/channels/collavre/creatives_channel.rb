module Collavre
  class CreativesChannel < ApplicationCable::Channel
    def subscribed
      return reject unless params[:root_id].present? && current_user

      @root = Creative.find_by(id: params[:root_id])&.effective_origin
      return reject unless @root
      return reject unless @root.has_permission?(current_user, :read)

      Rails.logger.info "[CreativesChannel] User #{current_user.email} subscribed to root #{@root.id}"
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
      payload = {
        editing: {
          creative_id: creative_id,
          user_id: current_user.id,
          user_name: current_user.display_name,
          avatar_url: user_avatar_url_for(current_user)
        }
      }
      broadcast_to_all_ancestors(creative_id, payload)
    end

    def stopped_editing(data)
      return unless @root && current_user

      creative_id = data["creative_id"].to_i
      payload = {
        stopped_editing: {
          creative_id: creative_id,
          user_id: current_user.id
        }
      }
      broadcast_to_all_ancestors(creative_id, payload)
    end

    private

    def broadcast_to_all_ancestors(creative_id, payload)
      @ancestor_roots_cache ||= {}
      roots = @ancestor_roots_cache[creative_id] ||= begin
        creative = Creative.find_by(id: creative_id)
        result = Set.new([ @root ])
        creative&.ancestors&.each { |a| result << a.effective_origin }
        result
      end
      roots.each { |root| CreativesChannel.broadcast_to(root, payload) }
    end

    def user_avatar_url_for(user)
      if user.avatar.attached?
        variant = user.avatar.variant(resize_to_limit: [ 48, 48 ])
        Rails.application.routes.url_helpers.rails_representation_path(
          variant, only_path: true
        )
      elsif user.respond_to?(:avatar_url) && user.avatar_url.present?
        user.avatar_url
      end
    end

    def broadcast_presence
      user_ids = CreativePresenceStore.list(@root.id)
      CreativesChannel.broadcast_to(@root, { presence: { user_ids: user_ids } })
    end
  end
end
