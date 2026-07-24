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

  # Statuses replayed to a subscriber that arrives after the activity started.
  # "pending_approval" is the one that MUST be here: the job has already returned
  # holding the task in that state, so unlike a mid-turn task there is no heartbeat
  # behind it and no later broadcast. A viewer who was disconnected — or who simply
  # reloaded — would otherwise never learn the task is still holding the topic slot,
  # and would be left without the Stop button on the one turn that is waiting on them.
  AGENT_REPLAY_STATUSES = %w[running pending pending_approval].freeze

  # Broadcast status for any currently live AI agent tasks for a creative.
  # Called when a user subscribes to ensure they see ongoing agent activity.
  def self.broadcast_running_agents(creative_id)
    Task.where(status: AGENT_REPLAY_STATUSES).find_each do |task|
      task_creative_id = task.trigger_event_payload&.dig("creative", "id")
      next unless task_creative_id == creative_id

      broadcast_agent_status(
        creative_id,
        # Replayed with its real status, not a blanket "thinking": the client keys
        # its own handling off this string, and a paused turn is not a working one.
        status: task.status == "pending_approval" ? "pending_approval" : "thinking",
        agent_id: task.agent_id,
        agent_name: task.agent.display_name,
        task_id: task.id,
        source_creative_id: task_creative_id
      )
    end
  end

  # Broadcast agent status (thinking/streaming/idle) to presence channel.
  # This allows the frontend typing indicator to show AI agent activity.
  # source_creative_id: the actual creative where agent is working (for filtering on frontend)
  def self.broadcast_agent_status(creative_id, status:, agent_id:, agent_name:, task_id: nil, content: nil, source_creative_id: nil)
    payload = {
      agent_status: {
        id: agent_id,
        name: agent_name,
        status: status,
        task_id: task_id,
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
