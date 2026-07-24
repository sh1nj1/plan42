module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    # Slack is acked (200) the instant this job is enqueued, so a lost job means a
    # lost message. We can't use a job-level `retry_on`: re-running `perform` would
    # re-run CommandProcessor's non-idempotent commands (/calendar, /work, MCP). So
    # CommandProcessor runs exactly once and each DB write around it is retried in
    # place via #with_transient_retry.

    # Retrying can't help these — the record was deleted, the payload can't
    # deserialize, or it's structurally invalid — so discard to let the queue self-heal.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound
    discard_on ActiveRecord::RecordInvalid

    def perform(payload)
      data = payload.with_indifferent_access

      creative = Collavre::Creative.find(data[:creative_id])
      user = Collavre.user_class.find_by(id: data[:user_id])
      channel_link = SlackChannelLink.find_by(id: data[:slack_channel_link_id])

      return unless creative && channel_link

      comment_user = user.presence || channel_link.created_by

      # Idempotent permission grant / invite writes. Run BEFORE the exactly-once claim so
      # a transient failure here (e.g. a Solid Queue enqueue deadlock that exhausts the
      # in-place retries) commits no reservation — a failed-job retry can still reprocess
      # the message. Each re-checks the existing share/invitation, so a sequential re-run
      # is a no-op. Retried in place on transient contention — otherwise a Deadlocked here
      # loses the acked message.
      with_transient_retry do
        # Case 1: User exists in Collavre but lacks permission
        if user && !creative.has_permission?(user, :feedback)
          grant_feedback_permission(creative: creative, user: user, granter: channel_link.created_by)
          Rails.logger.info("[CollavreSlack] Granted feedback permission to user #{user.id} on creative #{creative.id}")
        end

        # Case 2: User not in Collavre - invite by email
        if user.nil? && data[:slack_email].present?
          invite_user_by_email(
            creative: creative,
            email: data[:slack_email],
            inviter: channel_link.created_by
          )
          Rails.logger.info("[CollavreSlack] Sent invitation to #{data[:slack_email]} for creative #{creative.id}")
        end
      end

      # Exactly-once guard, claimed here: after the idempotent writes above, immediately
      # before the non-idempotent CommandProcessor (/calendar, /work, MCP). Slack is acked
      # before this job runs, so a message can arrive twice (sequentially or concurrently);
      # a read-only "already applied?" check can't cover concurrency — both jobs read "not
      # applied" and both run the commands. We atomically claim (channel_link, message_ts)
      # via a unique index, so only the winner runs CommandProcessor and persists.
      #
      # Placed after the reads and the idempotent writes so no recoverable failure leaves a
      # reservation behind: every pre-claim error is either a deterministic RecordNotFound
      # (deleted creative) or a transient grant/invite failure a retry can redo. Only past
      # the claim do we reach the non-idempotent commands, so the sole loss window is a
      # discard/crash between the claim and the comment persisting — intentional, since a
      # retry there would duplicate the commands. No time-lease (expiry reclaim is fragile).
      # channel_link is verified present, so a RecordInvalid can only mean "already claimed".
      return unless claim_inbound_message(data)

      # Create comment with appropriate user
      comment = Collavre::Comment.new(
        creative: creative,
        user: comment_user,
        content: format_comment_content(data[:content], user, data[:slack_display_name])
      )

      # Mark this comment as coming from Slack to prevent loop
      comment.instance_variable_set(:@from_slack, true)

      # Non-idempotent side effects: run once, outside the retryable write below.
      response = Collavre::Comments::CommandProcessor.new(comment: comment, user: user).call
      if response.present?
        comment.content = "#{comment.content}\n\n#{response}"
        comment.skip_dispatch = true  # slash command responses should not trigger AI
      end

      persist_comment_with_link!(comment, data)
    end

    private

    # Persist comment + Slack link atomically, retrying only this write (not the whole
    # job) so CommandProcessor isn't re-applied. `comment` is a fresh unsaved record,
    # so a rolled-back retry re-saves the same instance — exactly one comment and link.
    def persist_comment_with_link!(comment, data)
      with_transient_retry do
        ActiveRecord::Base.transaction do
          comment.save!

          # Create link between Slack message and comment for reaction sync
          if data[:slack_channel_link_id].present? && data[:slack_message_ts].present?
            SlackCommentLink.create!(
              comment: comment,
              slack_channel_link_id: data[:slack_channel_link_id],
              message_ts: data[:slack_message_ts]
            )
          end
        end
      end
    end

    # Retry an idempotent block on transient DB contention. Only wrap idempotent work
    # — the deliberate substitute for a job-level `retry_on`, which would also re-run
    # the non-idempotent CommandProcessor.
    def with_transient_retry(max_attempts: 5)
      attempts = 0
      begin
        yield
      rescue => e
        raise unless transient_contention?(e)

        attempts += 1
        raise if attempts >= max_attempts

        sleep(0.1 * (2**(attempts - 1)))
        retry
      end
    end

    # Whether an error is retryable transient contention, raised directly or wrapped.
    # Solid Queue re-raises a failed `deliver_later` enqueue INSERT as its own
    # EnqueueError with the original as #cause, so we match the cause chain — retrying
    # a wrapped Deadlocked/LockWaitTimeout while re-raising a wrapped permanent failure.
    def transient_contention?(error)
      seen = []
      while error && !seen.include?(error)
        return true if error.is_a?(ActiveRecord::Deadlocked) || error.is_a?(ActiveRecord::LockWaitTimeout)

        seen << error
        error = error.cause
      end
      false
    end

    # Atomically claim this message before the non-idempotent commands. True if we won the claim
    # (or there's no dedup key — same as prior behaviour), false if another job owns it.
    # Transient contention on the INSERT is retried in place, not a "claimed" signal.
    # Only uniqueness means already-claimed: RecordNotUnique is the authoritative gate
    # under concurrency, RecordInvalid covers the committed sequential case. channel_link
    # and message_ts are verified present, so uniqueness is the only validation that can
    # fail — RecordInvalid here unambiguously means "already claimed".
    def claim_inbound_message(data)
      channel_link_id = data[:slack_channel_link_id]
      message_ts = data[:slack_message_ts]
      return true unless channel_link_id.present? && message_ts.present?

      with_transient_retry do
        SlackInboundReservation.create!(
          slack_channel_link_id: channel_link_id,
          message_ts: message_ts
        )
      end
      true
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      false
    end

    def grant_feedback_permission(creative:, user:, granter:)
      # Check if share already exists
      existing_share = Collavre::CreativeShare.find_by(creative: creative, user: user)
      return if feedback_or_higher?(existing_share)

      if existing_share
        existing_share.update!(permission: :feedback)
      else
        Collavre::CreativeShare.create!(
          creative: creative,
          user: user,
          permission: :feedback,
          shared_by: granter
        )
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      # A concurrent message for the same user can create the share between the find_by
      # above and this write, tripping the (creative_id, user_id) uniqueness. The grant
      # is already satisfied, so re-check and treat as success — otherwise RecordInvalid
      # would hit the job's `discard_on` and drop this still-unposted message.
      raise unless feedback_or_higher?(Collavre::CreativeShare.find_by(creative: creative, user: user))
    end

    # Whether a CreativeShare grants feedback access or higher. `permission` is an enum
    # returning the string label, so rank it via the enum mapping like Permissible does.
    def feedback_or_higher?(share)
      return false unless share

      Collavre::CreativeShare.permissions.fetch(share.permission) >=
        Collavre::CreativeShare.permissions.fetch("feedback")
    end

    def invite_user_by_email(creative:, email:, inviter:)
      # A pre-existing invitation was created AND had its email enqueued in the same
      # transaction below, so there's nothing left to do. This dedups sequential
      # redelivery; a true concurrent double-delivery can still create two invitations
      # (no unique index on (creative_id, email)) — accepted, since a duplicate invite
      # email is far less harmful than a lost message. If such an index is ever added,
      # rescue RecordNotUnique + re-check here like #grant_feedback_permission does,
      # otherwise the concurrent loser's create! would escape as a hard job failure.
      existing_invitation = Collavre::Invitation.find_by(creative: creative, email: email)
      return if existing_invitation

      # Create invitation + enqueue email atomically. `deliver_later` enqueues
      # synchronously, so its INSERT joins this transaction; a transient EnqueueError
      # rolls both back and #with_transient_retry redoes them together. Without the
      # transaction, a committed invitation with a failed enqueue would, on retry, hit
      # the guard above and silently never send the email.
      ActiveRecord::Base.transaction do
        invitation = Collavre::Invitation.create!(
          email: email,
          inviter: inviter,
          creative: creative,
          permission: :feedback
        )
        Collavre::InvitationMailer.with(invitation: invitation).invite.deliver_later
      end
    end

    def format_comment_content(content, user, slack_display_name)
      # If user is mapped, no prefix needed (message will show their name)
      return content if user

      # If unmapped, prepend Slack username
      if slack_display_name.present?
        prefix = I18n.t("collavre_slack.messages.slack_user_prefix", name: slack_display_name)
        "#{prefix} #{content}"
      else
        content
      end
    end
  end
end
