module Collavre
  class Comment < ApplicationRecord
    self.table_name = "comments"

    STREAMING_PLACEHOLDER_CONTENT = "..."
    # Authorless "⏳" waiting-notice system messages posted when an agent is
    # deferred for topic concurrency. AgentOrchestrator.cleanup_waiting_notices!
    # matches the same prefix to remove them once the waiter is dequeued.
    WAITING_NOTICE_PREFIX = "⏳"

    # What a waiting notice speaks for, written by the door that posted it.
    # "topic" is the deduplicated notice coalescing allows a topic exactly one
    # of; "task" is the per-deferral notice the opt-out posts, which names its
    # waiter in waiting_notice_task_id. nil is a notice from before this was
    # recorded — see #cancel_queued_tasks_for_waiting_notice.
    WAITING_NOTICE_TOPIC = "topic"
    WAITING_NOTICE_TASK = "task"

    # Take down the per-deferral notice that speaks for this waiter, if it had
    # one.
    #
    # A "task" notice is on screen for exactly as long as its waiter is queued:
    # it names that waiter in waiting_notice_task_id and
    # #cancel_queued_tasks_for_waiting_notice stops that waiter and nothing
    # else. So the moment the waiter leaves the queue the notice is a stop
    # button for work that cannot be stopped — and no sweep will collect it,
    # since the drained sweep only runs when the topic queue empties and the
    # waiter itself will never be promoted again.
    #
    # It therefore comes down wherever the waiter leaves, which is why this
    # lives here beside the columns rather than in one of those callers: the
    # promotion (AgentOrchestrator.cleanup_waiter_notice!) and the fold
    # (Orchestration::TaskCoalescer) are two doors onto the same rule, and a
    # third would otherwise write its own copy or forget.
    #
    # The destroy is marked as a system removal: the waiter is being promoted or
    # folded, not abandoned by the user, so the cancellation callback must not
    # fire on top of it.
    def self.remove_waiter_notices!(creative_id:, topic_id:, task_ids:)
      task_ids = Array(task_ids).compact
      return if task_ids.empty?

      where(creative_id: creative_id, topic_id: topic_id, user_id: nil,
            waiting_notice_scope: WAITING_NOTICE_TASK,
            waiting_notice_task_id: task_ids).find_each do |notice|
        notice.suppress_waiter_cancellation = true
        notice.destroy
      end
    end

    # Take down every "⏳" defer notice in the topic that no longer speaks for a
    # queued waiter.
    #
    # Asked per notice, not per topic. "Is anything queued here?" is a topic-wide
    # question and no notice asks it: a "task" notice speaks for the one waiter
    # it names, and a shared one for every queued waiter *except* those a
    # surviving "task" notice claims — see #represented_queued_waiters, which
    # this and the stop button both go through so the two cannot drift. A topic
    # can therefore hold waiters while a notice standing in it represents none
    # of them, and that notice is a "⏳" line whose stop button selects nothing.
    #
    # Nothing else collects it. A cancelled waiter is never promoted, so the
    # promotion's cleanup never runs for it, and a promotion that leaves only
    # claimed waiters behind is exactly the case a topic-wide drain check reads
    # as "still busy".
    #
    # Scoped to topic_concurrency_defer notices. A :delayed notice shares the
    # prefix but explains a rate-limited or busy dispatch that is still going to
    # run, so it speaks for no waiter by design and is not this sweep's to take.
    #
    # Asked under the same lock the notice doors take, so "nobody is queued" is
    # a deferral's own before-or-after rather than a guess: it either commits
    # its waiter before this reads, and keeps its notice, or after, and posts
    # one of its own.
    def self.remove_stranded_waiting_notices!(creative_id:, topic_id:)
      transaction do
        Collavre::Orchestration::TopicSlot.lock!(topic_id, creative_id)

        where(creative_id: creative_id, topic_id: topic_id, user_id: nil,
              topic_concurrency_defer: true).find_each do |notice|
          next if notice.represented_queued_waiters.any?

          notice.suppress_waiter_cancellation = true
          notice.destroy
        end
      end
    end

    # Use non-namespaced partial path for backward compatibility
    def to_partial_path
      "comments/comment"
    end

    # A system "⏳" waiting notice (no author) telling a user their agent is
    # deferred because another task holds the topic's running slot.
    def waiting_notice?
      user_id.nil? && content.to_s.start_with?(WAITING_NOTICE_PREFIX)
    end

    # The task holding this topic's concurrency slot — the blocker this waiting
    # notice is about. Lets the notice render a stop button that cancels the
    # blocker (freeing the topic so the deferred waiter proceeds) instead of
    # being an anonymous dead end. Resolved at render time rather than stored on
    # task_id, which Task#reply_comment keys on (a shared task_id would make the
    # blocker's reply_comment ambiguous).
    #
    # Two gates keep the button honest:
    #   1. Only THIS notice's own topic-concurrency defer qualifies. The same "⏳"
    #      notice is also posted for :delayed decisions (busy / rate_limited),
    #      which schedule a delayed job WITHOUT queuing a topic waiter —
    #      cancelling some unrelated running task would not unblock them.
    #      topic_concurrency_defer is set only on the :deferred path, so a
    #      :delayed notice never shows the button even when an unrelated queued
    #      waiter happens to share the topic. The queued_for_topic check then
    #      confirms a waiter is still actually pending on the slot.
    #   2. Resolve the blocker over occupying_topic_slot, not just running/
    #      delegated: a holder paused on pending_approval still occupies the slot
    #      and is cancellable, so the button must stay visible for it.
    # Returns nil once no slot holder remains — at which point the notice itself
    # is cleaned up.
    def topic_blocking_task
      return @topic_blocking_task if defined?(@topic_blocking_task)

      @topic_blocking_task =
        if topic_concurrency_defer? && topic_id &&
           Collavre::Task.queued_for_topic(topic_id, creative_id).exists?
          Collavre::Task.occupying_topic_slot(topic_id, creative_id)
                        .includes(:agent).order(:created_at).first
        end
    end

    belongs_to :creative, class_name: "Collavre::Creative", counter_cache: true
    belongs_to :user, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :approver, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :action_executed_by, class_name: Collavre.configuration.user_class_name, optional: true
    belongs_to :task, class_name: "Collavre::Task", optional: true
    belongs_to :topic, class_name: "Collavre::Topic", optional: true
    belongs_to :quoted_comment, class_name: "Collavre::Comment", optional: true

    scope :public_only, -> { where(private: false) }

    # SQL inverse of Comment#approval_action? (action.present?). Approval-surface
    # messages must never reach an AI agent — not only at the dispatch seams but
    # also as chat-history/trigger context — so agent-context queries exclude them.
    scope :without_approval_action, -> { where("action IS NULL OR action = ''") }

    scope :visible_to, ->(user) {
      where(
        "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
        false, user.id, user.id
      )
    }

    # review_type: nil = normal chat, 0 = review, 1 = question
    enum :review_type, { review: 0, question: 1 }, prefix: true

    # Must run before dependent: :destroy on comment_versions to clear FK
    before_destroy :nullify_selected_version

    has_many :activity_logs, class_name: "Collavre::ActivityLog", dependent: :destroy
    has_many :comment_reactions, class_name: "Collavre::CommentReaction", dependent: :destroy
    has_many :comment_versions, class_name: "Collavre::CommentVersion", dependent: :destroy
    has_many :review_versions, class_name: "Collavre::CommentVersion", foreign_key: :review_comment_id, dependent: :nullify
    has_many :quoting_comments, class_name: "Collavre::Comment", foreign_key: :quoted_comment_id, dependent: :destroy
    has_one :snapshot_as_result, class_name: "Collavre::CommentSnapshot", foreign_key: :result_comment_id, dependent: :nullify
    belongs_to :selected_version, class_name: "Collavre::CommentVersion", optional: true

    has_many_attached :images, dependent: :purge_later

    include Broadcastable
    include Notifiable
    include Approvable
    include ClaudeChannelPermission

    attribute :skip_default_user, :boolean, default: false
    attribute :skip_dispatch, :boolean, default: false
    attribute :skip_link_preview, :boolean, default: false
    attribute :skip_notification_revision, :boolean, default: false
    # Set by AgentOrchestrator.cleanup_waiting_notices! so destroying a notice as
    # part of *promoting* a waiter does not run the user-delete cancel cascade
    # (which would cancel other still-queued waiters in the same topic).
    attribute :suppress_waiter_cancellation, :boolean, default: false

    before_validation :use_origin_creative
    before_validation :assign_default_user, on: :create
    before_validation :assign_main_topic, on: :create
    after_commit :enqueue_link_preview, on: [ :create, :update ], if: :link_preview_enqueue_required?
    after_create_commit :dispatch_to_orchestration
    after_create_commit :resume_trigger_loop_if_awaiting

    validates :content, presence: true, unless: -> { images.attached? }
    validate :creative_must_be_origin_creative
    validate :images_must_be_images

    after_destroy_commit :cancel_pending_tasks

    def next_version_number
      (comment_versions.maximum(:version_number) || 0) + 1
    end

    def review_message?
      quoted_comment_id.present? && !review_type_question?
    end

    # Which of `ids` are review requests, in one query. The orchestration paths
    # that decide whether a trigger may be folded away or moved forward hold
    # comment *ids*, not records, and run over a whole burst at once.
    #
    # `review_type: [nil, review]` rather than `where.not(question)`: the column
    # is NULL for an ordinary review (only /compress-style questions set it), and
    # SQL's `review_type != 1` drops NULL rows — which is every real review.
    def self.review_message_ids(ids)
      ids = Array(ids).compact.map(&:to_i).uniq
      return [] if ids.empty?

      review_messages.where(id: ids).pluck(:id)
    end

    scope :review_messages, -> {
      where.not(quoted_comment_id: nil).where(review_type: [ nil, review_types[:review] ])
    }

    # public for db migration
    def creative_snippet
      creative.creative_snippet
    end

    # Build the dispatch payload for comment_created events.
    # Used by both after_create_commit callback and DropTriggerJob
    # to ensure a single source of truth (no payload drift).
    def dispatch_payload
      {
        comment: {
          id: id,
          content: content,
          user_id: user_id,
          from_ai: user&.searchable? || false,
          quoted_comment_id: quoted_comment_id
        }.compact,
        creative: {
          id: creative_id,
          description: creative&.description
        },
        topic: {
          id: topic_id
        },
        chat: {
          content: content
        }
      }
    end

    private

    def nullify_selected_version
      update_column(:selected_version_id, nil) if selected_version_id.present?
    end

    def cancel_pending_tasks
      stranded_scopes = []

      # Cancel tasks triggered by this comment (no creative_id scoping —
      # CommentMoveService can change comment.creative_id without updating
      # existing tasks, so scoping would miss moved-comment tasks).
      # Include "delegated" so a deleted prompt also cancels Claude Channel
      # work that's still waiting on an external MCP reply — otherwise the
      # delegated task keeps holding the topic/agent slot until stuck recovery.
      Task.where(status: %w[pending running queued delegated]).find_each do |task|
        next unless task.trigger_event_payload&.dig("comment", "id") == id

        # An un-started task can be the survivor of a coalesced burst, answering
        # several comments at once. Cancelling it because its anchor was deleted
        # would throw away the absorbed comments too — they have no task of their
        # own left (TaskCoalescer cancelled those) and no other delivery path
        # (session-backed agents receive only the trigger). Re-anchor onto the
        # newest surviving merged comment instead; only a task with nothing left
        # to say is cancelled.
        next if reanchor_coalesced_task(task)

        was_delegated = task.status == "delegated"
        task.update!(status: "cancelled")

        # A waiter cancelled here leaves the queue without ever being promoted,
        # exactly as a folded one does — so the notice that spoke for it is left
        # naming a task no longer queued, and its stop button cancels nothing.
        # This door needs no policy change at all: the opt-out posts the notice,
        # deleting the prompt cancels the waiter, and a sibling still parked
        # keeps the drained sweep from ever running.
        Comment.remove_waiter_notices!(
          creative_id: task.creative_id, topic_id: task.topic_id, task_ids: task.id
        )

        # …and with coalescing on there is no per-deferral notice to take down:
        # the waiter's signal is the topic's *shared* one, which the call above
        # deliberately leaves alone. If this cancellation was the last thing that
        # notice spoke for, nothing else will ever collect it. Swept after the
        # loop, once every task this deletion cancels has left the queue.
        stranded_scopes << [ task.creative_id, task.topic_id ]

        # Delegated tasks live past their job: the AiAgentJob already returned,
        # holding the agent slot under task.id and counting against the per-topic
        # serializer. Mirror the cancel path used elsewhere to free both.
        next unless was_delegated
        if task.agent
          Collavre::Orchestration::ResourceTracker.for(task.agent).release!(task.id)
        end
        Collavre::Orchestration::AgentOrchestrator.dequeue_next_for_topic(task.topic_id, task.creative_id)
      end

      # Cancel queued tasks when a user DELETES their waiting notice. Gated to
      # topic_concurrency_defer notices: only the :deferred path queues a topic
      # waiter, so a :delayed (busy / rate_limited) "⏳" notice — which shares the
      # prefix but has no waiter of its own — must not cancel an unrelated queued
      # waiter that happens to share the topic. Also skipped when the notice is
      # removed by promotion cleanup (suppress_waiter_cancellation): there the
      # waiter is being advanced, not abandoned, and cancelling other still-queued
      # waiters would drop their work (multi-slot orphan recovery must not cancel
      # the rest).
      stranded_scopes.uniq.each do |cancelled_creative_id, cancelled_topic_id|
        next unless cancelled_creative_id

        Comment.remove_stranded_waiting_notices!(
          creative_id: cancelled_creative_id, topic_id: cancelled_topic_id
        )
      end

      if waiting_notice? && topic_concurrency_defer? && !suppress_waiter_cancellation
        cancel_queued_tasks_for_waiting_notice
      end
    end

    # Move a coalesced task off this (deleted) comment and onto the newest of
    # the comments it had absorbed. Returns true when the task was rescued, so
    # the caller skips cancellation.
    #
    # Only un-started tasks: a `running`/`delegated` task has already been handed
    # its payload, so re-anchoring changes nothing and deleting the prompt must
    # still stop the turn.
    def reanchor_coalesced_task(task)
      return false unless %w[queued pending].include?(task.status)

      Task.transaction { reanchor_locked_task(task) }
    rescue ActiveRecord::RecordNotFound
      # The task went away between the scan and the lock (a cascading delete).
      # Nothing to rescue, and nothing left to cancel either.
      false
    end

    # The lock body. `task` is the object cancel_pending_tasks' scan loaded, and
    # everything derived here has to come from the row as it stands *now*:
    # TaskCoalescer folds a sibling into this same task under a lock this path
    # never took, so a fold committing between that scan and the write below
    # would be overwritten by the pre-fold payload — and the absorbed sibling is
    # already cancelled, so its comment has no task left to answer it.
    #
    # lock! reloads in place rather than into a second object: the caller keeps
    # using this instance (it cancels the task when we return false), so swapping
    # identity here would hand it stale attributes.
    #
    # Status is re-read for the same reason. A snapshot that said `queued` may
    # have been promoted and started since, and a started turn has already been
    # handed its payload — deleting the prompt must stop it, not re-target it.
    def reanchor_locked_task(task)
      task.lock!
      return false unless %w[queued pending].include?(task.status)

      payload = task.trigger_event_payload || {}
      merged = Array(payload[Collavre::Orchestration::TaskCoalescer::PAYLOAD_KEY])
                 .compact.map(&:to_i).uniq - [ id ]
      return false if merged.empty?

      # Anything else in the merge window may have been deleted too. Newest by id:
      # created_at is stamped per writing process, so a burst can carry skewed or
      # tied timestamps (same reason MergedTriggerComments orders by id).
      #
      # Scoped to this turn's creative/topic: a merged comment moved elsewhere
      # while the task waited (CommentMoveService#perform_move reassigns
      # creative_id) is no longer part of it, and adopting it as the anchor would
      # point the reply at a creative the agent may have no share on.
      #
      # The turn is the TASK's scope, not this comment's. cancel_pending_tasks
      # looks tasks up with no creative scoping precisely because a move rewrites
      # the comment without touching the task it triggered — so an anchor moved
      # away and then deleted would be searching the creative it was moved *to*,
      # find nothing there, and cancel a turn whose absorbed comments are all
      # still sitting in the creative the task belongs to.
      #
      # Asked through MergedTriggerComments.in_turn, the same predicate that
      # decides what the turn delivers. Eligibility is not only about *where* a
      # comment is: a comment made private (or turned into an approval surface)
      # after it was absorbed is one dispatch_to_orchestration would refuse to
      # trigger on, and in_turn already drops it from the merged blocks. The
      # anchor is delivered as the trigger itself, with no filter in front of
      # it, so a lookup of its own here is how withdrawn content reaches the
      # agent through the one door that never filters.
      in_scope = Collavre::AiAgent::MergedTriggerComments
                   .in_turn(merged, "creative" => { "id" => task.creative_id },
                                    "topic" => { "id" => task.topic_id })
                   .order(:id).to_a
      replacement = in_scope.last
      return false unless replacement

      # Through the same door the refresh uses, so the promotion is recorded as
      # an acquired anchor either way: this task was created to answer the
      # comment being deleted, not this one.
      payload = Collavre::Orchestration::TaskCoalescer.reanchor_payload(payload, replacement)
      payload = payload.merge(
        # Rebuilt from the in-scope ids rather than merged through
        # absorb_into_payload, which would fold the out-of-scope ones straight
        # back in from the payload it starts from. The new anchor is excluded so
        # the promoted comment is not delivered twice.
        Collavre::Orchestration::TaskCoalescer::PAYLOAD_KEY =>
          (in_scope.map(&:id) - [ replacement.id ]).sort
      )
      task.update!(trigger_event_payload: payload)

      Rails.logger.info(
        "[Comment#cancel_pending_tasks] Re-anchored coalesced task #{task.id} from deleted " \
        "comment #{id} to comment #{replacement.id}"
      )
      true
    end

    # Cancel *every* queued waiter this notice speaks for, not just the newest.
    #
    # Cancelling one was right while each deferral posted its own notice: the
    # newest queued task was the one that notice belonged to. A topic now gets
    # exactly one deduplicated notice
    # (Orchestration::AgentOrchestrator.with_deduped_topic_notice), and with
    # topic_max_concurrent_jobs > 1 it can stand for waiters from several agents
    # — coalescing folds same-agent siblings only. Deleting it while cancelling
    # one of them leaves the rest queued with nothing on screen representing
    # them and no stop control, and nothing reposts a notice until the next
    # deferral happens by.
    #
    # …but only a notice that actually *was* deduplicated. With
    # coalesce_pending_tasks off, post_waiting_notice deliberately skips the
    # dedup path and posts one notice per deferral: there the 1:1 still holds and
    # cancelling every queued task would let a user discard unrelated waiters by
    # dismissing one notice, defeating the opt-out.
    #
    # Which kind this is comes off the row (waiting_notice_scope), written by
    # whichever door posted it. It used to be inferred from whether a sibling
    # notice still stood, on the reasoning that the dedup path allows a topic
    # exactly one — but the two kinds coexist as soon as the policy differs
    # between agents or changes while a topic still has waiters, and then the
    # inference inverts: the shared notice reads as a per-deferral one and takes
    # down the newest queued waiter, which is very likely the one the *other*
    # notice speaks for. A row cannot be classified by its neighbours when the
    # neighbours are a different kind.
    #
    # Queued only. A task holding the topic slot (pending/running/…) is not
    # waiting on anything; the notice surfaces it separately as
    # topic_blocking_task, with its own stop button.
    def cancel_queued_tasks_for_waiting_notice
      represented_queued_waiters.each { |task| task.update!(status: "cancelled") }

      # Cancelling is the other way a topic queue empties, and it has no
      # promotion behind it to run the drained check. The notices that spoke for
      # the waiters just cancelled went with them — this one is being destroyed,
      # and a per-deferral sibling names a task that is now cancelled — but a
      # *shared* notice is only ever taken down by that check, so without this
      # it is left on screen describing a wait that is over.
      Comment.remove_stranded_waiting_notices!(creative_id: creative_id, topic_id: topic_id)
    end

    # The queued waiters this notice speaks for — what its stop button cancels,
    # and equally what keeps it on screen. Public because
    # .remove_stranded_waiting_notices! asks the same question from the other
    # side: a notice representing nobody is a stop control for work that can no
    # longer be stopped. Two answers to one question is how the button and the
    # sweep would come to disagree about what a notice is for.
    public def represented_queued_waiters
      case waiting_notice_scope
      when WAITING_NOTICE_TASK
        # Speaks for exactly the waiter it was posted with — and for nothing at
        # all once that waiter has been folded away or promoted.
        queued_topic_waiters.select { |task| task.id == waiting_notice_task_id }
      when WAITING_NOTICE_TOPIC
        # Every queued waiter in the topic except those a per-deferral notice
        # speaks for: the shared notice was never their signal, and their own
        # stop control is — or is about to be — on screen.
        #
        # Asked of the waiter, not of the notices standing beside it. A waiter and
        # its notice commit in two steps, so an opted-out waiter is queued before
        # any notice names it; classifying it by what survives in that window
        # cancels a turn that was only deferred, and leaves no notice behind to
        # say so. What speaks for a waiter is settled when it is parked.
        claimed = sibling_notice_waiter_ids
        queued_topic_waiters.reject { |task| task_claims_own_notice?(task, claimed) }
      else
        # Posted before this was recorded. Nothing on the row says which kind it
        # was, so keep the behaviour those notices were created under rather than
        # guess: widening it would discard work, narrowing it would disarm the
        # only stop control an in-flight wait has.
        queued_topic_waiters.first(1)
      end
    end

    def queued_topic_waiters
      scope = Task.where(status: "queued", creative_id: creative_id)
      scope = topic_id ? scope.where(topic_id: topic_id) : scope.where(topic_id: nil)
      scope.order(created_at: :desc).to_a
    end

    # Does this waiter have a per-deferral notice of its own, rather than being
    # one the topic's shared notice speaks for?
    #
    # The waiter says so itself, recorded when it was parked. Rows parked before
    # that was recorded say nothing, so they keep the answer they were parked
    # under — the surviving sibling notices — rather than being guessed at in
    # either direction: widening this discards work, narrowing it disarms the only
    # stop control an in-flight wait has.
    def task_claims_own_notice?(task, claimed)
      case task.waiting_notice_scope
      when WAITING_NOTICE_TASK then true
      when WAITING_NOTICE_TOPIC then false
      else claimed.include?(task.id)
      end
    end

    # Waiter ids a still-standing per-deferral notice represents. Runs
    # after_destroy_commit, so this notice is already out of the query.
    def sibling_notice_waiter_ids
      Comment.where(creative_id: creative_id, topic_id: topic_id, user_id: nil,
                    waiting_notice_scope: WAITING_NOTICE_TASK)
             .pluck(:waiting_notice_task_id).compact
    end

    def dispatch_to_orchestration
      return if private?
      return if skip_default_user  # system notices should not trigger AI
      return if skip_dispatch      # explicit opt-out (e.g., command processor responses)
      return if approval_action?   # approval button / approved message: human decision surface, never dispatch to an agent
      return unless user_id        # nil user = system message
      return if user&.ai_user?     # AI replies use A2aDispatcher, not this callback
      return unless creative
      # Inbox creatives hold the user's notifications AND ordinary conversations.
      # Only the System topic is special: it carries alarms/notifications (stuck
      # recovery, share notices, …) and must never trigger AI. Every OTHER inbox
      # topic — Main, Content, user threads, Claude Channel session topics — is an
      # ordinary conversation surface and dispatches exactly like a normal
      # (non-inbox) topic.
      #
      # A live Claude Channel session holds inbox-wide :feedback +
      # routing_expression="true", so it would otherwise be selected by the
      # Matcher for *every* dispatched inbox comment (leaking ordinary inbox
      # threads into the live session). That confinement now lives in
      # Orchestration::Matcher, which scopes a Claude session agent to its own
      # registered session topic — keeping non-System topics truly identical to a
      # normal topic whether or not a session is live.
      return if creative.inbox? && inbox_system_topic?

      # A Claude Channel session suspended on a native tool-permission prompt
      # parks its in-flight dispatch as a `delegated` task carrying a
      # pending_tool_call (stamped by /agent/notify when the prompt is relayed).
      # An intervening human comment posted while the task is parked is dispatched
      # normally — not suppressed. The delegated task holds the topic's only
      # concurrency slot (running_for_topic counts `delegated`,
      # topic_max_concurrent_jobs=1), so the scheduler defers the comment into a
      # `queued` task rather than a competing turn, and
      # AgentOrchestrator.dequeue_next_for_topic promotes it (refreshed to the
      # latest comment) when the parked task is finalized on /reply. Suppressing
      # it here would silently drop the follow-up instead of deferring it — worst
      # when the local Claude TUI answered the prompt, leaving pending_tool_call
      # set on the server for the rest of a locally-approved tool run.

      SystemEvents::Dispatcher.dispatch("comment_created", dispatch_payload)
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#dispatch_to_orchestration] Failed for comment #{id}: " \
        "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
      )
      raise  # re-raise so calling jobs (e.g. DropTriggerJob) can retry
    end

    # The inbox System topic is the alarm/notification stream and must never
    # trigger AI orchestration. Matched by name (Creative::SYSTEM_TOPIC_NAME),
    # the same topic Creative#system_topic finds/creates and that stuck-recovery
    # and share notices post into.
    def inbox_system_topic?
      topic&.name == Creative::SYSTEM_TOPIC_NAME
    end

    def assign_default_user
      return if skip_default_user
      self.user ||= Collavre.current_user
    end

    # When a human user comments in a trigger topic that is awaiting user input,
    # auto-resume the trigger loop so the agent can continue working.
    def resume_trigger_loop_if_awaiting
      return unless user_id                # must have a user (not system)
      return if user&.ai_user?             # must be a human, not an AI agent
      return if approval_action?           # approval surface is not a user-resume signal; the resumed @agent turn would otherwise carry it into history
      return unless creative

      # Use pessimistic lock to prevent duplicate resume from concurrent comments
      iteration = nil
      max = nil
      creative.with_lock do
        loop_data = creative.data&.dig("trigger", "loop")
        return unless loop_data && loop_data["state"] == "awaiting_user"

        # Only resume if this comment is in the trigger topic
        trigger_topic_id = loop_data["trigger_topic_id"]
        return if trigger_topic_id.present? && trigger_topic_id != topic_id

        # Transition to running and post continue instruction atomically
        data = creative.data || {}
        trigger = data["trigger"] || {}
        loop_cfg = trigger["loop"] || {}
        iteration = loop_cfg["current_iteration"] || 0
        max = loop_cfg["max_iterations"] || 10
        loop_cfg["state"] = "running"
        trigger["loop"] = loop_cfg
        data["trigger"] = trigger
        creative.update!(data: data)
      end

      # Post continue instruction outside lock (state already committed)
      return unless iteration # guard: lock block returned early

      parent = creative.parent
      return unless parent&.drop_trigger_enabled?

      agent = parent.find_ai_agent(:write)
      return unless agent

      creative.comments.create!(
        content: "@#{agent.name}: #{I18n.t(
          'collavre.trigger_loop.user_resumed',
          iteration: iteration,
          max: max
        )}",
        topic_id: topic_id,
        private: false,
        user: creative.user,
        skip_dispatch: false
      )
    rescue StandardError => e
      Rails.logger.error(
        "[Comment#resume_trigger_loop_if_awaiting] Failed for comment #{id}: " \
        "#{e.class} #{e.message}"
      )
    end

    def assign_main_topic
      return if topic_id.present?
      return unless creative

      fallback = user || Collavre.current_user || creative.user
      self.topic = creative.main_topic(fallback_user: fallback)
    end

    def use_origin_creative
      return unless creative
      self.creative = creative.effective_origin
    end

    def creative_must_be_origin_creative
      return unless creative
      return unless creative.origin_id.present?

      errors.add(:creative, "must be an origin creative")
    end

    def enqueue_link_preview
      return if content.blank?

      CommentLinkPreviewJob.perform_later(id, content, notification_revision)
    end

    def link_preview_enqueue_required?
      saved_change_to_content? && !skip_link_preview
    end

    def images_must_be_images
      return unless images.attached?

      invalid_images = images.reject { |image| image.blob&.content_type&.start_with?("image/") }
      return if invalid_images.empty?

      errors.add(:images, "must be an image")
      invalid_images.each(&:purge)
    end
  end
end
