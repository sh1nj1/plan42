class CommentsPresenceChannel < ApplicationCable::Channel
  def subscribed
    Rails.logger.info "User #{current_user&.email} subscribed to comments presence for creative #{params[:creative_id]}"
    return unless params[:creative_id].present? && current_user

    @creative_id = Creative.find(params[:creative_id].to_i).effective_origin.id
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    broadcast_presence
  end

  def unsubscribed
    if @creative_id && current_user
      CommentPresenceStore.remove(@creative_id, current_user.id)
      broadcast_presence
    end
  end

  private

  def stream_name
    "comments_presence:#{@creative_id}"
  end

  def broadcast_presence
    ids = CommentPresenceStore.list(@creative_id)
    Rails.logger.info "Broadcasting presence for creative #{@creative_id} to #{stream_name}, users: #{ids.join(', ')}"
    html = ApplicationController.render(
      partial: "comments/presence_avatars",
      locals: { creative: Creative.find(@creative_id), present_ids: ids }
    )
    ActionCable.server.broadcast(stream_name, { html: html })
  end
end
