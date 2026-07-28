module Collavre
class CommentsPresenceChannel < ApplicationCable::Channel
  def self.broadcast_channel_chips_changed(creative_id, topic_id:)
    ActionCable.server.broadcast(
      "comments_presence:#{creative_id}",
      { channel_chips: { topic_id: topic_id } }
    )
  end

  def self.broadcast_shares_changed(creative_id, shared_user_id:, permission: nil, action: "updated", has_access: nil, can_comment: nil, has_access_changed: nil, can_comment_changed: nil)
    ActionCable.server.broadcast(
      "comments_presence:#{creative_id}",
      {
        shares_changed: {
          user_id: shared_user_id,
          permission: permission,
          action: action,
          has_access: has_access,
          can_comment: can_comment,
          has_access_changed: has_access_changed,
          can_comment_changed: can_comment_changed
        }
      }
    )
  end

  # Broadcast status for any currently running AI agent tasks for a creative.
  # Called when a user subscribes to ensure they see ongoing agent activity.
  def self.broadcast_running_agents(creative_id, topic_id: nil)
    creative = Creative.find_by(id: creative_id)
    return unless creative

    Task.where(status: %w[running pending]).find_each do |task|
      task_creative_id = task.trigger_event_payload&.dig("creative", "id")
      next unless task_creative_id == creative_id

      task_topic_id = AiAgent::AgentLifecycleManager.topic_id_for(task: task, creative: creative)
      next if topic_id && task_topic_id.to_s != topic_id.to_s

      broadcast_agent_status(
        creative_id,
        status: "thinking",
        agent_id: task.agent_id,
        agent_name: task.agent.display_name,
        task_id: task.id,
        topic_id: task_topic_id,
        source_creative_id: task_creative_id
      )
    end
  end

  # Broadcast agent status (thinking/streaming/idle) to presence channel.
  # This allows the frontend typing indicator to show AI agent activity.
  # source_creative_id: the actual creative where agent is working (for filtering on frontend)
  def self.broadcast_agent_status(creative_id, status:, agent_id:, agent_name:, topic_id:, task_id: nil, content: nil, source_creative_id: nil)
    payload = {
      agent_status: {
        id: agent_id,
        name: agent_name,
        status: status,
        task_id: task_id,
        topic_id: topic_id,
        creative_id: source_creative_id || creative_id
      }
    }
    payload[:agent_status][:content] = content if content.present?
    ActionCable.server.broadcast("comments_presence:#{creative_id}", payload)
  end

  def subscribed
    Rails.logger.info "User #{current_user&.email} subscribed to comments presence for creative #{params[:creative_id]}"
    return unless params[:creative_id].present? && current_user

    @creative_id = Creative.find(params[:creative_id].to_i).effective_origin.id
    creative = Creative.find(@creative_id)
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    Comment.broadcast_badge(creative, current_user)
    broadcast_presence
    CommentsPresenceChannel.broadcast_running_agents(@creative_id)
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

  def typing(data)
    return unless @creative_id && current_user

    topic_id = topic_id_for(data)
    return unless topic_id

    ActionCable.server.broadcast(
      stream_name,
      { typing: { id: current_user.id, name: current_user.display_name, topic_id: topic_id } }
    )
  end

  def stopped_typing(data)
    return unless @creative_id && current_user

    topic_id = topic_id_for(data)
    return unless topic_id

    ActionCable.server.broadcast(stream_name, { stop_typing: { id: current_user.id, topic_id: topic_id } })
  end

  def running_agents(data)
    return unless @creative_id && current_user

    topic_id = topic_id_for(data)
    return unless topic_id

    CommentsPresenceChannel.broadcast_running_agents(@creative_id, topic_id: topic_id)
  end

  private

  def topic_id_for(data)
    topic_id = data["topic_id"] || data[:topic_id]
    Topic.find_by(id: topic_id, creative_id: @creative_id)&.id
  end

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
