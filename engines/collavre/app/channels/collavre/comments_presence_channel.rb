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

  # One agent_status payload per currently live AI agent task on a creative, in
  # the shape broadcast_agent_status sends.
  def self.running_agent_payloads(creative_id)
    Task.where(status: AGENT_REPLAY_STATUSES).filter_map do |task|
      task_creative_id = task.trigger_event_payload&.dig("creative", "id")
      next unless task_creative_id == creative_id

      agent_status_payload(
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

  # Broadcast status for any currently live AI agent tasks for a creative.
  # #subscribed does NOT use this — it transmits the same payloads straight to
  # the connection instead, because a broadcast can be dropped exactly there
  # (see the comment on that call).
  def self.broadcast_running_agents(creative_id)
    running_agent_payloads(creative_id).each do |payload|
      ActionCable.server.broadcast("comments_presence:#{creative_id}", payload)
    end
  end

  # Broadcast agent status (thinking/streaming/idle) to presence channel.
  # This allows the frontend typing indicator to show AI agent activity.
  # source_creative_id: the actual creative where agent is working (for filtering on frontend)
  def self.broadcast_agent_status(creative_id, status:, agent_id:, agent_name:, task_id: nil, content: nil, source_creative_id: nil)
    ActionCable.server.broadcast(
      "comments_presence:#{creative_id}",
      agent_status_payload(
        creative_id,
        status: status, agent_id: agent_id, agent_name: agent_name,
        task_id: task_id, content: content, source_creative_id: source_creative_id
      )
    )
  end

  def self.agent_status_payload(creative_id, status:, agent_id:, agent_name:, task_id: nil, content: nil, source_creative_id: nil)
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
    payload
  end

  def subscribed
    Rails.logger.info "User #{current_user&.email} subscribed to comments presence for creative #{params[:creative_id]}"
    return reject unless params[:creative_id].present? && current_user

    creative = Creative.find_by(id: params[:creative_id].to_i)&.effective_origin
    # The only gate on this channel. Everything below hands the subscriber content
    # of the creative — the reader list, the unread badge, and the live task ids,
    # statuses and agent names replayed at the end — and none of it is re-checked
    # per message. active_statuses filters by :read for the same data; a channel
    # that streams it to any signed-in id would just be the unfiltered way in.
    return reject unless creative&.has_permission?(current_user, :read)

    @creative_id = creative.id
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    Comment.broadcast_badge(creative, current_user)
    broadcast_presence
    # Transmitted to this connection, not broadcast to the stream it just joined.
    # `stream_from` only registers the subscription with the pubsub adapter, and
    # the async and Redis adapters do that asynchronously — a broadcast published
    # in the same breath can land before the subscription is attached and be
    # dropped. Every other message here survives that (presence and badges are
    # re-sent by later events), but this replay is one-shot: the job that set
    # pending_approval has already returned, so a dropped copy means no Stop
    # button for the rest of the turn.
    self.class.running_agent_payloads(@creative_id).each { |payload| transmit(payload) }
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
