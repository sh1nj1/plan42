module Collavre
class CommentsPresenceChannel < ApplicationCable::Channel
  def subscribed
    Rails.logger.info "User #{current_user&.email} subscribed to comments presence for creative #{params[:creative_id]}"
    return unless params[:creative_id].present? && current_user

    @creative_id = Creative.find(params[:creative_id].to_i).effective_origin.id
    creative = Creative.find(@creative_id)
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    Comment.broadcast_badge(creative, current_user)
    broadcast_presence
  end

  def unsubscribed
    if @creative_id && current_user
      CommentPresenceStore.remove(@creative_id, current_user.id)
      creative = Creative.find(@creative_id)
      pointer = CommentReadPointer.find_or_initialize_by(user: current_user, creative: creative)
      pointer.last_read_comment_id = creative.comments.maximum(:id)
      pointer.save!
      Comment.broadcast_badge(creative, current_user)
      broadcast_presence
    end
  end

  def typing
    return unless @creative_id && current_user

    ActionCable.server.broadcast(
      stream_name,
      { typing: { id: current_user.id, name: current_user.display_name } }
    )
  end

  def stopped_typing
    return unless @creative_id && current_user

    ActionCable.server.broadcast(stream_name, { stop_typing: { id: current_user.id } })
  end

  private

  def stream_name
    "comments_presence:#{@creative_id}"
  end

  def broadcast_presence
    ids = CommentPresenceStore.list(@creative_id)
    Rails.logger.info "Broadcasting presence for creative #{@creative_id} to #{stream_name}, users: #{ids.join(', ')}"
    ActionCable.server.broadcast(stream_name, { ids: ids })
  end
end
end
