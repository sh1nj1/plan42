module CollavreSlack
  class SlackInboundMessageJob < ApplicationJob
    queue_as :default

    # SlackEventsController acks Slack with 200 the instant it enqueues this job
    # (ack-before-apply), so Slack never re-delivers the event once accepted.
    # Without a retry, a transient DB contention error on the final write would
    # park the job and the inbound Slack message would be lost permanently.
    #
    # We deliberately do NOT use a job-level `retry_on` for transient contention:
    # re-running the whole `perform` would re-run CommandProcessor, whose commands
    # (/calendar -> CalendarEvent, /work -> tasks, MCP commands) have
    # non-idempotent, non-transactional side effects that already committed on the
    # first attempt. A whole-job retry would duplicate those side effects. Instead
    # CommandProcessor runs exactly once, and the DB writes on either side of it
    # are wrapped in an in-place #with_transient_retry: the pre-command permission
    # grant / invite writes (both idempotent — each checks for an existing record
    # first) and the final comment+link write. Every point where a transient
    # Deadlocked/LockWaitTimeout can surface is covered, without ever re-running
    # the non-idempotent commands.

    # Permanent/unprocessable failures: retrying cannot help. The referenced
    # creative/user/link was deleted, the payload can no longer deserialize, or a
    # record is structurally invalid. Discard so the queue self-heals rather than
    # looping forever.
    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound
    discard_on ActiveRecord::RecordInvalid

    def perform(payload)
      data = payload.with_indifferent_access

      # Idempotency guard. The controller acks Slack before this job runs
      # (at-least-once delivery), and this job has multiple non-atomic writes. If a
      # completed run is somehow re-delivered, reprocessing the same Slack message
      # would create a duplicate comment. The (channel_link, message_ts) pair
      # uniquely identifies the inbound message, so a matching SlackCommentLink
      # means it was already applied — no-op.
      return if slack_message_already_applied?(data)

      creative = Collavre::Creative.find(data[:creative_id])
      user = Collavre.user_class.find_by(id: data[:user_id])
      channel_link = SlackChannelLink.find_by(id: data[:slack_channel_link_id])

      return unless creative && channel_link

      comment_user = user.presence || channel_link.created_by

      # Pre-command permission grant / invite writes run before the non-idempotent
      # CommandProcessor, so they must not be part of a whole-job retry. They are
      # each idempotent (checking for an existing record first), so we retry them
      # in place on transient contention — otherwise a Deadlocked here would lose
      # the already-acked Slack message.
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

      # Create comment with appropriate user
      comment = Collavre::Comment.new(
        creative: creative,
        user: comment_user,
        content: format_comment_content(data[:content], user, data[:slack_display_name])
      )

      # Mark this comment as coming from Slack to prevent loop
      comment.instance_variable_set(:@from_slack, true)

      # Command side effects must happen exactly once — run before the retryable
      # write and never inside the retry loop.
      response = Collavre::Comments::CommandProcessor.new(comment: comment, user: user).call
      if response.present?
        comment.content = "#{comment.content}\n\n#{response}"
        comment.skip_dispatch = true  # slash command responses should not trigger AI
      end

      persist_comment_with_link!(comment, data)
    end

    private

    # Persist the comment and its Slack link atomically, retrying only this write
    # on transient DB contention. Retrying here (rather than the whole job) keeps
    # the non-idempotent CommandProcessor side effects from being re-applied.
    # Because `comment` is a fresh unsaved record, a rolled-back attempt re-saves
    # the same instance, so retries produce exactly one comment and one link.
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

    # Retry an idempotent block on transient DB contention with exponential
    # backoff. Only ever wrap idempotent work — a retry re-runs the block from the
    # top. This is the deliberate substitute for a job-level `retry_on`, which
    # would also re-run the non-idempotent CommandProcessor.
    def with_transient_retry(max_attempts: 5)
      attempts = 0
      begin
        yield
      rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
        attempts += 1
        raise if attempts >= max_attempts

        sleep(0.1 * (2**(attempts - 1)))
        retry
      end
    end

    def slack_message_already_applied?(data)
      return false unless data[:slack_channel_link_id].present? && data[:slack_message_ts].present?

      SlackCommentLink.exists?(
        slack_channel_link_id: data[:slack_channel_link_id],
        message_ts: data[:slack_message_ts]
      )
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
      # A concurrent inbound message for the same user can create the share between
      # our find_by above and this write, tripping the (creative_id, user_id)
      # uniqueness validation (RecordInvalid) or its backing unique index
      # (RecordNotUnique). The grant is already satisfied by that other job, so
      # re-check and treat it as success. Without this, the RecordInvalid would
      # escape to the job's global `discard_on ActiveRecord::RecordInvalid` and
      # drop this still-unposted Slack message even though the grant succeeded.
      raise unless feedback_or_higher?(Collavre::CreativeShare.find_by(creative: creative, user: user))
    end

    # Whether a CreativeShare already grants feedback access or higher. `permission`
    # is an enum whose reader returns the string label, so rank it against the enum
    # mapping the same way Collavre::Creative::Permissible does.
    def feedback_or_higher?(share)
      return false unless share

      Collavre::CreativeShare.permissions.fetch(share.permission) >=
        Collavre::CreativeShare.permissions.fetch("feedback")
    end

    def invite_user_by_email(creative:, email:, inviter:)
      # A pre-existing invitation means an earlier attempt already created it AND
      # enqueued its email in the same transaction (below), so there is nothing
      # left to do — this guard is only ever hit for a genuinely repeated invite,
      # never for a partially-applied one.
      existing_invitation = Collavre::Invitation.find_by(creative: creative, email: email)
      return if existing_invitation

      # Create the invitation and enqueue its email atomically. `deliver_later`
      # enqueues synchronously (enqueue_after_transaction_commit is false), so the
      # Solid Queue enqueue INSERT participates in this transaction. If that INSERT
      # raises a transient Deadlocked/LockWaitTimeout, the invitation create rolls
      # back with it and the enclosing #with_transient_retry redoes both together.
      # Without this transaction, a committed invitation with a failed enqueue
      # would, on retry, hit the existing-invitation guard above and silently
      # never send the email.
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
