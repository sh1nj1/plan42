# frozen_string_literal: true

module Collavre
  module Screening
    # Screens one agent turn and applies the server policy to the verdict:
    #
    #   passed  -> deliver
    #   flagged -> deliver with owner-approved tools, or block where the server
    #              cannot gate tools (block_flagged:, e.g. Claude Channel)
    #   error   -> pause for the agent owner's approval (ScreeningPendingError)
    #   blocked -> fail the task, tell the sender, raise CancelledError
    #
    # The approver is always the agent's owner, never the creative owner: the
    # sender may own the creative and must not approve their own turn.
    class TurnGuard
      EXCERPT_CHARS = 500

      def initialize(task:, agent:, creative:, context:, principal:, authors: [])
        @task, @agent, @creative = task, agent, creative
        @context, @principal, @authors = context || {}, principal, authors
      end

      # Returns "skipped", "passed", "approved" or "flagged".
      def call(texts, block_flagged:)
        return "skipped" if Current.screening

        # Taken first: a denial ends the turn even if screening was turned
        # off while it waited.
        decision = take_decision!
        return "skipped" unless Screening.enabled?
        return "skipped" if Scope.for(agent: @agent, context: @context, principal: @principal, authors: @authors) == :skip

        digest = Screening.digest(texts)
        if decision && decision["content_digest"] == digest
          approved!(decision, digest)
          # The owner approved what a failed screener could not answer for;
          # another screener's flag still applies.
          return decision["residual"] == "flagged" ? apply_flag(block_flagged) : "approved"
        end

        verdict = Gate.new.call(texts, agent: @agent, creative: @creative, task: @task)
        case verdict.verdict
        when "passed" then "passed"
        when "flagged" then apply_flag(block_flagged)
        when "blocked" then block!(:blocked_notice)
        else request_approval!(texts, digest, verdict)
        end
      end

      private

      # The owner's answer to an earlier pause, removed from the task so it
      # is used once. An approval covers exactly the content it was asked
      # about; anything else is screened again.
      def take_decision!
        pending = @task.pending_tool_call
        return unless pending&.dig("kind") == PENDING_KIND

        @task.update!(pending_tool_call: nil)
        decision = pending["decision"]
        return unless decision && decision["decided_by"] == pending["approver_id"]
        block!(:denied_notice) if decision["decision"] == "denied"

        decision.merge(pending.slice("content_digest", "residual"))
      end

      def apply_flag(block_flagged)
        block_flagged ? block!(:blocked_notice) : "flagged"
      end

      def approved!(decision, digest)
        @task.task_actions.create!(action_type: ACTION_TYPE, status: "done",
          payload: { "verdict" => "owner_approved", "decided_by" => decision["decided_by"],
                     "policy_version" => POLICY_VERSION, "content_digest" => digest })
      end

      # An owner who cannot read the creative cannot decide, and an undecided
      # pause would hold the topic until someone stops it.
      def request_approval!(texts, digest, verdict)
        approver = @agent.creator
        block!(:blocked_notice) unless approver && @creative&.has_permission?(approver, :read)

        raise ScreeningPendingError.new(
          task: @task, approver: approver, content_digest: digest, residual: verdict.residual,
          question: approval_question(texts, verdict, approver)
        )
      end

      def approval_question(texts, verdict, approver)
        excerpt = texts.map { |entry| entry[:text].to_s }.join("\n\n").truncate(EXCERPT_CHARS)
        locale = approver.locale.presence || I18n.default_locale
        question = I18n.t("collavre.screening.approval_request", locale: locale,
          agent: @agent.display_name, error: verdict.error || verdict.screener_id,
          sender: @principal&.display_name || I18n.t("collavre.screening.unknown_sender", locale: locale),
          excerpt: excerpt.gsub(/^/, "> "))
        return question unless verdict.residual == "flagged"

        "#{question}\n\n#{I18n.t('collavre.screening.also_flagged', locale: locale)}"
      end

      def block!(notice)
        @task.with_lock { @task.update!(status: "failed") if @task.status.in?(%w[running delegated]) }
        post_notice(notice)
        raise CancelledError
      end

      # Best effort: the turn is already failed, and a missing notice must not
      # turn a clean block into an unexplained job failure.
      def post_notice(notice)
        return unless @creative && @task.topic_id

        locale = @principal&.locale.presence || I18n.default_locale
        @creative.comments.create!(
          topic_id: @task.topic_id, user: @agent, skip_default_user: true, skip_dispatch: true,
          content: I18n.t("collavre.screening.#{notice}", locale: locale, agent: @agent.display_name)
        )
      rescue StandardError => e
        Rails.logger.error("[Screening] notice for task #{@task.id} failed: #{e.class}")
      end
    end
  end
end
