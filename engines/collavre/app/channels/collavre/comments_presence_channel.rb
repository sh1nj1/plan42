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

  # Narrowed by creative in SQL, not in Ruby: a pending_approval turn sits until
  # somebody answers it, so the replayable set is unbounded and deployment-wide,
  # and every subscribe would otherwise load all of it just to keep one creative's
  # rows. tasks.creative_id is written from the same context["creative"]["id"] the
  # payload carries (AiAgentJob#admit_or_defer!, park_waiter, WorkflowExecutor,
  # WorkCommand), and is indexed. A row can only lose it to the FK's on_delete:
  # :nullify, and a deleted creative already returns [] above.
  #
  # Ordered by id because the client appends these into a per-agent array and stops
  # the last one. Not created_at: turns are stamped by whichever process dispatched
  # them, so a web/worker clock skew can invert two of them (see PR #1431).
  def self.replayable_tasks(creative_id)
    Task.where(status: AGENT_REPLAY_STATUSES, creative_id: creative_id).order(:id)
  end

  # Scoped to the creative the popup is open on, not to its origin: the client keeps
  # that id as this.creativeId and drops any payload naming a different one, and a
  # link is a placement — replaying every task under the origin would put another
  # user's shell id on the wire, which PermissionFilter#readable_ids exists to hide.
  # Topics hang off the origin, so that is what resolves a task's topic_id.
  def self.running_agent_payloads(creative_id, topic_id: nil)
    creative = Creative.find_by(id: creative_id)&.effective_origin
    return [] unless creative

    replayable_tasks(creative_id).filter_map do |task|
      # Still checked: the column is what the query trusts, the payload is what the
      # client is handed back as source_creative_id, and a row where the two
      # disagree must not name a creative it was not dispatched on.
      task_creative_id = task.trigger_event_payload&.dig("creative", "id")
      next unless task_creative_id == creative_id

      task_topic_id = AiAgent::AgentLifecycleManager.topic_id_for(task: task, creative: creative)
      next if topic_id && task_topic_id.to_s != topic_id.to_s

      agent_status_payload(
        creative_id,
        # Replayed with its real status, not a blanket "thinking": the client keys
        # its own handling off this string, and a paused turn is not a working one.
        status: task.status == "pending_approval" ? "pending_approval" : "thinking",
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
    ActionCable.server.broadcast(
      "comments_presence:#{creative_id}",
      agent_status_payload(
        creative_id,
        status: status, agent_id: agent_id, agent_name: agent_name, topic_id: topic_id,
        task_id: task_id, content: content, source_creative_id: source_creative_id
      )
    )
  end

  def self.agent_status_payload(creative_id, status:, agent_id:, agent_name:, topic_id:, task_id: nil, content: nil, source_creative_id: nil)
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
    payload
  end

  def subscribed
    Rails.logger.info "User #{current_user&.email} subscribed to comments presence for creative #{params[:creative_id]}"
    return reject unless params[:creative_id].present? && current_user

    requested = Creative.find_by(id: params[:creative_id].to_i)
    creative = requested&.effective_origin
    # The only gate on this channel — nothing below is re-checked per message, and
    # active_statuses already filters the same task data by :read.
    return reject unless creative&.has_permission?(current_user, :read)

    @creative_id = creative.id
    # Kept for the whole subscription, not just for the replay below: comments live on
    # the origin, so everything else on this channel is keyed by @creative_id, while
    # a task is dispatched on — and replayed for — the creative the popup is open on.
    # #running_agents replays too, and reading @creative_id there would search the
    # origin for rows that only ever carried the shell's id.
    @requested_creative_id = requested.id
    stream_from stream_name
    CommentPresenceStore.add(@creative_id, current_user.id)
    Comment.broadcast_badge(creative, current_user)
    broadcast_presence
    # Transmitted, not broadcast: stream_from attaches asynchronously, so a broadcast
    # published in the same breath can be dropped. Presence and badges survive that
    # (later events re-send them); this replay is one-shot.
    replay_running_agents
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

  # The client clears its agent state on every topic switch and asks for the new
  # topic's snapshot. A pending_approval turn has no heartbeat behind it, so this
  # replay is the only thing that can put its indicator and Stop button back.
  def running_agents(data)
    return unless @creative_id && current_user

    topic_id = topic_id_for(data)
    return unless topic_id

    replay_running_agents(topic_id: topic_id)
  end

  private

  # Transmitted to the connection that asked, never broadcast: the stream is per
  # origin and shared by every viewer of it, so publishing one client's snapshot
  # there would re-push agent state to everyone — including viewers sitting on a
  # different topic, whose own state the client would then have to reconcile.
  def replay_running_agents(topic_id: nil)
    self.class
        .running_agent_payloads(@requested_creative_id, topic_id: topic_id)
        .each { |payload| transmit(payload) }
  end

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
