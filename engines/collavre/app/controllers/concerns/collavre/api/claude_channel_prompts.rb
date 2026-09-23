# frozen_string_literal: true

module Collavre
  module Api
    # Builds the approval comments a Claude Channel session raises through
    # /agent/notify, and parks the dispatch that is waiting on one.
    #
    # Two shapes share the rail. A native tool-permission prompt is relayed by
    # Claude Code mid-turn and its text is rendered here from the structured
    # tool_name/arguments. An approval_request is raised by the agent itself and
    # its text is the agent's own question. Either way the human's approve/deny
    # travels back over the agent stream to the tool call it is blocking.
    module ClaudeChannelPrompts
      extend ActiveSupport::Concern

      # Raised when a relayed approval_request is malformed: a blank question, a
      # missing correlation id, or an approver who cannot see the creative. The
      # plugin surfaces the 422 body to the agent as the tool's error result, so
      # it can correct the call — mirroring how the native approval_request tool
      # returns its validation errors instead of parking the turn.
      class InvalidApprovalRequest < StandardError; end

      private

      # An approval request, a relayed tool prompt, or a plain out-of-band notice.
      def build_notify_comment(creative, topic, agent)
        return build_approval_request_comment(creative, topic, agent) if params.key?(:approval_question)
        return build_permission_comment(creative, topic, agent) if params[:permission_request_id].present?

        creative.comments.build(
          content: params[:text].to_s,
          topic: topic,
          user: agent,
          skip_default_user: true,
          skip_dispatch: true
        )
      end

      # Build a structured tool-permission comment that reuses the native
      # approval UI (approver gate + approve/deny buttons). The prompt text is
      # rendered server-side via I18n (localized for the viewer), not formatted
      # by the plugin. The action payload carries the request_id so the
      # eventual approve/deny relays the exact decision to the suspended
      # session. approver is the token holder driving this Claude session — the
      # only human who should resolve its prompts.
      def build_permission_comment(creative, topic, agent)
        tool_name = params[:tool_name].to_s.strip.presence || "tool"
        args_raw = sanitize_permission_arguments(params[:arguments])
        description = params[:description].to_s.strip

        action_payload = {
          "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
          "request_id" => params[:permission_request_id].to_s,
          "tool_name" => tool_name,
          "description" => description,
          "arguments" => args_raw
        }

        creative.comments.build(
          content: permission_prompt_content(tool_name, description, args_raw),
          topic: topic,
          user: agent,
          approver: current_user,
          action: JSON.pretty_generate(action_payload),
          skip_default_user: true,
          skip_dispatch: true
        )
      end

      # Build an agent-initiated approval request: the Claude Channel counterpart
      # of the native approval_request gate. The agent's own question is the
      # comment body (verbatim, as the native gate persists it) and the approver
      # gate plus approve/deny buttons come from the shared approval comment UI.
      #
      # Unlike a relayed tool prompt the text is NOT server-rendered: it is the
      # agent's question, which the native tool documents as markdown. Nothing is
      # interpolated into a fence or emphasis span here, so there is no delimiter
      # to escape — the body renders exactly like any other comment.
      #
      # The same permission_request_id rail carries the eventual decision back to
      # the blocked tool call, so the plugin's pending/replay bookkeeping and the
      # in-flight task parking both work unchanged.
      def build_approval_request_comment(creative, topic, agent)
        question = params[:approval_question].to_s.strip
        raise InvalidApprovalRequest, I18n.t("collavre.approval_gate.question_required") if question.blank?
        if params[:permission_request_id].blank?
          raise InvalidApprovalRequest, I18n.t("collavre.approval_gate.request_id_required")
        end

        creative.comments.build(
          content: question,
          topic: topic,
          user: agent,
          approver: resolve_approval_request_approver(creative),
          action: JSON.pretty_generate({
            "action" => Comment::ClaudeChannelPermission::ACTION_TYPE,
            "kind" => Comment::ClaudeChannelPermission::KIND_APPROVAL_REQUEST,
            "request_id" => params[:permission_request_id].to_s,
            "question" => question
          }),
          skip_default_user: true,
          skip_dispatch: true
        )
      end

      # Who decides. Defaults to the token holder driving this session (as for a
      # relayed tool prompt — already gated on :feedback above). An explicit
      # approver_user_id lets the agent route the decision to someone else, and is
      # validated exactly as Tools::ApprovalRequestService.approver! validates the
      # native gate's: a human (never an AI user) who can read the creative.
      def resolve_approval_request_approver(creative)
        id = params[:approver_user_id].presence
        return current_user if id.blank?

        approver = User.find_by(id: id)
        unless approver && !approver.ai_user? &&
            (creative.user == approver || creative.has_permission?(approver, :read))
          raise InvalidApprovalRequest, I18n.t("collavre.approval_gate.invalid_approver")
        end
        approver
      end

      # The API base controller authenticates the bearer token but does not run
      # the host app's locale switching, so I18n.locale is the process default
      # here. Render the persisted prompt in the token holder's locale
      # explicitly — they are the approver who will read it.
      def permission_prompt_content(tool_name, description, args_raw)
        I18n.with_locale(current_user&.locale.presence || I18n.default_locale) do
          I18n.t(
            "collavre.claude_channel.permission.message",
            tool_name: format_permission_tool_name(tool_name),
            description: format_permission_description(description),
            arguments: format_permission_arguments(args_raw)
          )
        end
      end

      # Coerce the arguments param into a JSON-safe value: a permitted Hash, a
      # plain string, or nil. ActionController::Parameters must be unwrapped or
      # JSON.pretty_generate raises on unpermitted parameters.
      def sanitize_permission_arguments(arguments)
        return nil if arguments.blank?

        arguments.respond_to?(:to_unsafe_h) ? arguments.to_unsafe_h : arguments
      end

      # Render the (already sanitized) tool arguments for the prompt body. The
      # result is interpolated inside a ```json fence and the comment is later
      # passed through renderCommentMarkdown, so the value must never be able to
      # close that fence. A string input_preview (the documented shape for many
      # tools, e.g. a Bash command) is therefore JSON-serialized rather than
      # emitted raw: that escapes embedded newlines to \n, collapsing it to a
      # single line so no payload line can begin a ``` delimiter and break out
      # into live markdown that misleads the approver.
      def format_permission_arguments(arguments)
        return I18n.t("collavre.claude_channel.permission.no_arguments") if arguments.blank?

        JSON.pretty_generate(arguments)
      end

      # Render the optional human-readable permission summary Claude Code sends
      # alongside the structured fields. Absent for most tools, so it collapses
      # to an empty string (no stray blockquote); when present it is the only
      # plain-language description of what the approver is allowing.
      def format_permission_description(description)
        return "" if description.blank?

        # The description renders into a "> %{text}" blockquote, so any newline
        # would drop the remainder onto a fresh line where it could open a
        # heading or ```fence and escape into live markdown. Flatten line breaks
        # to whitespace so the whole summary stays inside the one blockquote line
        # (inline backticks there are harmless — a fence must start a line).
        flattened = description.gsub(/\s*\R\s*/, " ").strip
        I18n.t("collavre.claude_channel.permission.description", text: flattened)
      end

      # Render the tool name for the prompt. Unlike description/arguments it is
      # interpolated into a "**%{tool_name}**" emphasis span and the comment is
      # later passed through renderCommentMarkdown, so an unescaped value (e.g. a
      # third-party MCP tool name) could close the surrounding "**", or — via an
      # embedded newline — start a fresh-line heading/fence and misrepresent which
      # tool the approver is authorizing. Flatten line breaks to whitespace and
      # backslash-escape markdown metacharacters so the name always renders
      # literally. The raw name is still kept in the action payload.
      def format_permission_tool_name(tool_name)
        flattened = tool_name.gsub(/\s*\R\s*/, " ").strip
        flattened.gsub(/([\\`*_{}\[\]()#+\-.!~>|<])/) { "\\#{$1}" }
      end

      # When the relayed comment is a native tool-permission prompt (carries a
      # permission_request_id), park the in-flight dispatch as "awaiting a
      # decision" by stamping pending_tool_call on its delegated task.
      # Comment#dispatch_to_orchestration then relays the human's subsequent
      # allow/deny straight to this suspended session instead of queuing it
      # behind the delegated topic slot (which would deadlock — the task holds
      # the slot it is itself waiting to be unblocked on). Cleared when the
      # task is completed (/reply) or cancelled (unregister/stuck recovery).
      def park_pending_permission(topic, agent, requested_task_id, request_id)
        return if request_id.blank? || requested_task_id.blank?

        task = Task.where(topic_id: topic.id, status: "delegated", agent_id: agent.id)
                   .find_by(id: requested_task_id)
        task&.update_column(:pending_tool_call, {
          "request_id" => request_id.to_s,
          "requested_at" => Time.current.iso8601
        })
      end
    end
  end
end
