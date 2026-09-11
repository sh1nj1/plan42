module Collavre
  module AiAgent
    module WorkspaceAuthentication
      private

      def stream_with_handoff(resolved)
        stream_response(@client, resolved)
      ensure
        # Preserve acceptance even when cancellation or authentication leaves by exception.
        Orchestration::DeliveryRecord.mark_handed_off!(@task) if @client.handed_off?
      end

      # Permission-cache updates do not cancel running tasks. Recheck after
      # prompt preparation, bypassing this worker's SQL cache before handoff.
      def check_replay_permission!
        return if CliProxy::ReplayClaims.ids(@context).empty?
        return if Task.uncached { Orchestration::Matcher.permits_creative_access?(@context, @agent) }

        @task.cancel_if_active!
        raise CancelledError
      end

      def handle_engine_login(error)
        @lifecycle_manager.check_cancelled!(force: true)
        CliProxy::InlineLogin.record!(@task, @reply_comment, error, content: @streamer.content,
                                    retryable: !@client.handed_off?)
        Rails.logger.info "[AiAgent] engine_unauthenticated task_id=#{@task.id} agent_id=#{@agent.id} " \
                          "engine=#{error.engine} workspace_id=#{error.workspace.id} reply_comment_id=#{@reply_comment&.id || 'none'}"
        @lifecycle_manager.broadcast_status("idle")
        nil
      end

      def workspace_user
        @workspace_user ||= begin
          carried_principal = @context.key?("workspace_user_id")
          carried_user = User.find_by(id: @context["workspace_user_id"])
          comment_user = @original_comment&.user

          if carried_user && !carried_user.ai_user?
            carried_user
          elsif carried_principal
            nil
          elsif comment_user && !comment_user.ai_user?
            comment_user
          else
            @agent.creator
          end
        end
      end
    end
  end
end
