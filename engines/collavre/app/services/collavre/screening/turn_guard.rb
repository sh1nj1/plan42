# frozen_string_literal: true

module Collavre
  module Screening
    # Screens one agent turn and applies the server policy to the verdict:
    #
    #   passed  -> deliver
    #   flagged -> pause for the agent owner's approval before delivery
    #   error   -> SystemSetting.screening_error_policy: pause for the agent
    #              owner's approval (default), deliver unscreened, or block
    #   blocked -> fail the task, tell the sender, raise CancelledError
    #
    # The approver is always the agent's owner, never the creative owner: the
    # sender may own the creative and must not approve their own turn.
    class TurnGuard
      EXCERPT_CHARS = 500

      def initialize(task:, agent:, creative:, context:, principal:, authors: [])
        @task, @agent, @creative = task, agent, creative
        @execution_generation = Orchestration::ExecutionFence.generation(task)
        @context, @principal, @authors = context || {}, principal, authors
      end

      def call(texts, unverified_context: false)
        return "skipped" if Current.screening

        # Taken first: a denial ends the turn even if screening was turned
        # off while it waited.
        decision = take_decision!
        return "skipped" unless Screening.enabled?
        return "skipped" if !unverified_context && outside_scope?

        digest = Screening.digest(texts)
        if decision && decision["content_digest"] == digest
          renew_legacy_approval!(texts, digest, decision)
          approved!(decision, digest)
          return "approved"
        end

        verdict = Gate.new.call(texts, agent: @agent, creative: @creative, task: @task)
        case verdict.verdict
        when "passed" then "passed"
        when "blocked" then block!(:blocked_notice)
        when "flagged" then request_approval!(texts, digest, verdict)
        else resolve_unanswered!(texts, digest, verdict)
        end
      end

      # Text that joins a turn after it was screened, such as an approval
      # reason replayed into a resumed conversation. It cannot pause the turn
      # (the turn is mid-conversation), so an unanswered screening flags it.
      def screen_followup(texts, block_flagged:)
        return "skipped" if Current.screening || !Screening.enabled?
        return "skipped" if outside_scope?

        verdict = Gate.new.call(texts, agent: @agent, creative: @creative, task: @task)
        case verdict.verdict
        when "passed" then "passed"
        when "blocked" then block!(:blocked_notice)
        when "flagged" then apply_flag(block_flagged)
        else flag_unanswered_followup!(texts, block_flagged, verdict)
        end
      end

      def apply_flag(block_flagged)
        block_flagged ? block!(:blocked_notice) : "flagged"
      end

      private

      def outside_scope?
        Scope.for(agent: @agent, context: @context, principal: @principal, authors: @authors) == :skip
      end

      # A screener that could not answer follows the configured error policy.
      # Passing waives only the unanswered screening: a flag from a screener
      # that did answer still asks the owner.
      def resolve_unanswered!(texts, digest, verdict)
        case SystemSetting.screening_error_policy
        when "block" then block!(:unscreened_notice)
        when "pass"
          flagged = Verdict.new(verdict: "flagged", residual: "flagged")
          return request_approval!(texts, digest, flagged) if verdict.residual == "flagged"

          record_unscreened_pass!(digest)
        else request_approval!(texts, digest, verdict)
        end
      end

      def record_unscreened_pass!(digest)
        @task.task_actions.create!(action_type: ACTION_TYPE, status: "done",
          payload: { "verdict" => "passed", "reason" => "error_policy_pass",
                     "policy_version" => POLICY_VERSION, "content_digest" => digest })
        "passed"
      end

      # A flag is recorded even when a screener answered it: Gate audits only
      # each screener's strictest verdict, so a screener that flagged one chunk
      # and failed on another leaves no flag for a later resume to restore.
      def flag_unanswered_followup!(texts, block_flagged, verdict)
        policy = SystemSetting.screening_error_policy
        block!(:unscreened_notice) if policy == "block"
        waived = policy == "pass"
        return record_unscreened_pass!(Screening.digest(texts)) if waived && verdict.residual != "flagged"

        block!(:blocked_notice) if block_flagged

        @task.task_actions.create!(action_type: ACTION_TYPE, status: "done",
          payload: { "verdict" => "flagged", "reason" => waived ? "followup_residual_flag" : "followup_screening_error",
                     "policy_version" => POLICY_VERSION, "content_digest" => Screening.digest(texts) })
        "flagged"
      end

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

        decision.merge(pending.slice("content_digest", "residual", "policy_version"))
      end

      # Older prompts presented approval as permission to deliver with every
      # tool separately gated. Ask again before delivering under the new policy.
      def renew_legacy_approval!(texts, digest, decision)
        return unless decision["residual"] == "flagged" && decision["policy_version"].nil?

        request_approval!(texts, digest, Verdict.new(verdict: "flagged", residual: "flagged"))
      end

      def approved!(decision, digest)
        @task.task_actions.create!(action_type: ACTION_TYPE, status: "done",
          payload: { "verdict" => "owner_approved", "decided_by" => decision["decided_by"],
                     "residual" => decision["residual"],
                     "policy_version" => POLICY_VERSION, "content_digest" => digest })
      end

      # An owner who cannot read the creative cannot decide, and an undecided
      # pause would hold the topic until someone stops it.
      def request_approval!(texts, digest, verdict)
        approver = @agent.creator
        block!(:blocked_notice) unless approver && @creative&.has_permission?(approver, :read)

        raise ScreeningPendingError.new(
          task: @task, approver: approver, content_digest: digest, residual: verdict.residual,
          execution_generation: @execution_generation,
          question: approval_question(texts, verdict, approver)
        )
      end

      def approval_question(texts, verdict, approver)
        excerpt = texts.map { |entry| entry[:text].to_s }.join("\n\n").truncate(EXCERPT_CHARS)
        locale = approver.locale.presence || I18n.default_locale
        key = verdict.verdict == "flagged" ? "flagged_approval_request" : "approval_request"
        question = I18n.t("collavre.screening.#{key}", locale: locale,
          agent: @agent.display_name, error: verdict.error || verdict.screener_id,
          sender: @principal&.display_name || I18n.t("collavre.screening.unknown_sender", locale: locale),
          excerpt: excerpt.gsub(/^/, "> "))
        return question unless verdict.residual == "flagged"

        "#{question}\n\n#{I18n.t('collavre.screening.also_flagged', locale: locale)}"
      end

      def block!(notice)
        @task.with_lock do
          raise CancelledError if Orchestration::ExecutionFence.superseded?(@task, @execution_generation)
          raise CancelledError unless @task.status.in?(%w[running delegated])

          @task.update!(status: "failed")
        end
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
