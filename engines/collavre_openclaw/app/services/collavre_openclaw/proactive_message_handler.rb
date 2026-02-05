module CollavreOpenclaw
  # Handles proactive (unsolicited) chat events from OpenClaw Gateway.
  #
  # Proactive messages arrive when the Gateway agent initiates communication
  # (e.g., cron jobs, heartbeats, reminders) without a prior request from Collavre.
  #
  # Events arrive as streaming deltas followed by a final event, just like
  # regular chat responses. This handler buffers deltas per runId and dispatches
  # the complete message to CallbackProcessorJob on final.
  #
  # Thread safety: called from the EventMachine reactor thread. All operations
  # should be non-blocking. Job enqueueing is safe from any thread.
  #
  # Stale buffer cleanup: buffers older than BUFFER_TTL are periodically purged
  # to prevent memory leaks when the Gateway never sends a final/error event.
  class ProactiveMessageHandler
    # Maximum age (seconds) for a buffer before it's considered stale and purged.
    # Generous timeout for long-running AI responses.
    BUFFER_TTL = 30.minutes.to_i

    # How often (seconds) to check for stale buffers.
    SWEEP_INTERVAL = 60

    def initialize
      @buffers = {}   # runId → { text:, session_key:, user_id:, created_at: }
      @mutex = Mutex.new
      @last_sweep_at = monotonic_now
    end

    # Process a single chat event payload from the WebSocket client.
    # Called by WebsocketClient#on_proactive_message.
    #
    # @param user [User] the user who owns the Gateway connection
    # @param payload [Hash] the chat event payload with :runId, :state, :message, :sessionKey
    def handle(user, payload)
      run_id = payload[:runId]
      return unless run_id

      sweep_stale_buffers_if_needed!

      state = payload[:state]&.to_s
      session_key = payload[:sessionKey]

      case state
      when "delta"
        buffer_delta(run_id, user, session_key, payload)
      when "final"
        handle_final(run_id, user, session_key, payload)
      when "error"
        handle_error(run_id, user, payload)
      when "aborted"
        cleanup(run_id)
      else
        # Unknown state — log and ignore
        Rails.logger.debug("[CollavreOpenclaw::Proactive] Unknown state '#{state}' for runId=#{run_id}")
      end
    end

    # Parse a session key into its component parts.
    # Format: agent:<agent_id>:collavre:<user_id>[:creative:<id>][:topic:<id>]
    #
    # @param session_key [String]
    # @return [Hash] with :agent_id, :user_id, :creative_id, :topic_id keys
    def self.parse_session_key(session_key)
      return {} unless session_key.present?

      result = {}
      parts = session_key.split(":")

      # Parse key:value pairs
      i = 0
      while i < parts.length - 1
        key = parts[i]
        value = parts[i + 1]

        case key
        when "agent"
          result[:agent_id] = value
          i += 2
        when "collavre"
          result[:user_id] = value.to_i
          i += 2
        when "creative"
          result[:creative_id] = value.to_i
          i += 2
        when "topic"
          result[:topic_id] = value.to_i
          i += 2
        else
          i += 1
        end
      end

      result
    end

    private

    def buffer_delta(run_id, user, session_key, payload)
      text = extract_text(payload)
      return unless text.present?

      @mutex.synchronize do
        buffer = @buffers[run_id] ||= {
          text: +"",
          session_key: session_key,
          user_id: user.id,
          created_at: monotonic_now
        }
        buffer[:text] << text
      end
    end

    def handle_final(run_id, user, session_key, payload)
      final_text = extract_text(payload)

      buffer = @mutex.synchronize { @buffers.delete(run_id) }

      # Prefer final text (complete message) over buffered deltas (fragments).
      # Fall back to buffered deltas only when final text is empty.
      content = if final_text.present?
                  final_text
      elsif buffer
                  buffer[:text]
      end

      return unless content.present?

      # Use session_key from final event, falling back to buffered
      effective_session_key = session_key || buffer&.dig(:session_key)
      context = self.class.parse_session_key(effective_session_key)

      dispatch_to_job(user, content, context)
    end

    def handle_error(run_id, _user, payload)
      error_msg = payload[:errorMessage] || payload.dig(:message, :content) || "Unknown error"
      Rails.logger.error("[CollavreOpenclaw::Proactive] Error for runId=#{run_id}: #{error_msg}")
      cleanup(run_id)
    end

    def cleanup(run_id)
      @mutex.synchronize { @buffers.delete(run_id) }
    end

    def extract_text(payload)
      message = payload[:message]
      return nil unless message.is_a?(Hash)

      content = message[:content]
      case content
      when String
        content
      when Array
        content.filter_map { |c| c[:text] if c[:type] == "text" }.join
      end
    end

    # Purge buffers older than BUFFER_TTL. Runs at most once per SWEEP_INTERVAL
    # to avoid scanning on every event.
    def sweep_stale_buffers_if_needed!
      now = monotonic_now
      return if (now - @last_sweep_at) < SWEEP_INTERVAL

      @last_sweep_at = now
      cutoff = now - BUFFER_TTL

      @mutex.synchronize do
        stale_ids = @buffers.each_with_object([]) do |(run_id, buf), ids|
          ids << run_id if buf[:created_at] && buf[:created_at] < cutoff
        end

        stale_ids.each do |run_id|
          @buffers.delete(run_id)
          Rails.logger.warn(
            "[CollavreOpenclaw::Proactive] Purged stale buffer for runId=#{run_id} " \
            "(older than #{BUFFER_TTL}s)"
          )
        end
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def dispatch_to_job(user, content, context)
      creative_id = context[:creative_id]

      unless creative_id.present?
        Rails.logger.warn("[CollavreOpenclaw::Proactive] No creative_id in session key, skipping. Context: #{context}")
        return
      end

      Rails.logger.info(
        "[CollavreOpenclaw::Proactive] Dispatching proactive message " \
        "(user=#{user.id}, creative=#{creative_id}, topic=#{context[:topic_id]})"
      )

      CallbackProcessorJob.perform_later(
        user.id,
        {
          "type" => "proactive",
          "content" => content,
          "creative_id" => creative_id,
          "context" => {
            "creative_id" => creative_id,
            "thread_id" => context[:topic_id]
          }
        }
      )
    end
  end
end
