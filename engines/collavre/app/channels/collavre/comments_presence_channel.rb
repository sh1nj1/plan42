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

  # Replayed to late subscribers. "pending_approval" must be here: its job already
  # returned, so no heartbeat or later broadcast will ever re-announce it, and a
  # reloading viewer would lose the Stop button on the turn that is waiting on them.
  AGENT_REPLAY_STATUSES = %w[running pending pending_approval].freeze

  # Ordered by id because the client appends these into a per-agent array and stops
  # the last one. Not created_at: turns are stamped by whichever process dispatched
  # them, so a web/worker clock skew can invert two of them (see PR #1431).
  def self.replayable_tasks
    Task.where(status: AGENT_REPLAY_STATUSES).order(:id)
  end

  def self.running_agent_payloads(creative_id)
    tasks = replayable_tasks.to_a
    origin_of = origin_ids_for(tasks)

    tasks.filter_map do |task|
      task_creative_id = task.trigger_event_payload&.dig("creative", "id")
      next unless origin_of[task_creative_id] == creative_id

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

  # Subscribers arrive with an effective origin (comments only ever live there), but
  # a turn dispatched on a linked creative keeps that link's id in its payload — so
  # match the way the live broadcast routes, via AgentLifecycleManager#broadcast_status.
  def self.origin_ids_for(tasks)
    ids = tasks.filter_map { |task| task.trigger_event_payload&.dig("creative", "id") }.uniq
    Creative.where(id: ids).each_with_object({}) do |creative, map|
      map[creative.id] = creative.effective_origin.id
    end
  end
  private_class_method :origin_ids_for

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
    # The only gate on this channel — nothing below is re-checked per message, and
    # active_statuses already filters the same task data by :read.
    return reject unless creative&.has_permission?(current_user, :read)

    @creative_id = creative.id
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    Comment.broadcast_badge(creative, current_user)
    broadcast_presence
    # Transmitted, not broadcast: stream_from attaches asynchronously, so a broadcast
    # published in the same breath can be dropped. Presence and badges survive that
    # (later events re-send them); this replay is one-shot.
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
