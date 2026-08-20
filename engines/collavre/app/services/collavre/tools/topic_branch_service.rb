module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Branches selected messages of a topic into a new topic, copying them.
  #
  # The context-length escape hatch. A topic that has run long is expensive for
  # every agent that reads it and hard for a person to re-enter, but the history
  # is not disposable. Branching carries the few messages the next stretch of
  # work actually depends on into a fresh topic and leaves the original intact
  # as the record.
  class TopicBranchService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_branch"
    tool_description <<~DESC.strip
      Branch a topic: create a new topic containing COPIES of selected messages
      from an existing one. The originals stay where they are.

      Use this to reset a conversation that has grown too long to carry, or to
      split one thread that has drifted into two subjects, while keeping the
      source topic as the record. To move messages instead of copying them, use
      topic_create with comment_ids.

      Get the message ids from topic_messages. At most
      #{::Collavre::TopicBranchService::MAX_BRANCH_COMMENTS} messages per branch
      — pick the ones the next stretch of work depends on rather than the whole
      history. Asking for more is an error, not a silent trim.

      The new topic is created on the same creative and records the source in
      source_topic_id. Requires feedback permission or better on the creative.
      Main and an inbox's System name are reserved and cannot be assigned to
      the branch.

      Approval prompts cannot be branched — a copy would lose the approval
      action and read as ordinary history. Passing one is an error.
    DESC

    tool_param :source_topic_id, description: "The topic to branch from."
    tool_param :comment_ids, description: "Comma-separated ids of the messages to copy, e.g. \"991,994,1002\". They must all belong to the source topic and be visible to you. Get ids from topic_messages."
    tool_param :name, description: "Name for the new topic. Defaults to a generated \"branch:<source name>\" name.", required: false

    sig do
      params(
        source_topic_id: Integer,
        comment_ids: T.any(String, Integer, T::Array[T.untyped]),
        name: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(source_topic_id:, comment_ids:, name: nil)
      user = Current.user || raise("Current.user is required")
      source = Topic.find(source_topic_id)
      TopicAuthorizer.authorize_read!(source, user: user)

      ids = IdList.parse(comment_ids)
      validate_ids!(ids)
      reject_approval_actions!(source, ids, user)

      # Fully qualified: inside Collavre::Tools, a bare TopicBranchService is
      # this tool, not the branching service it wraps.
      topic = ::Collavre::TopicBranchService.new(
        creative: source.creative, user: user, source_topic: source, name: name
      ).call(comment_ids: ids)

      Topics::Serializer.for_tool(topic).merge(source_topic_id: source.id, copied_count: ids.size)
    end

    private

    # TopicBranchService trims an oversized selection to its cap and reports
    # success for the shortened list, which is right for a UI that already
    # capped the selection but wrong here: a caller that pasted 150 ids would be
    # told it branched them and be missing 50 with nothing to read that says so.
    def validate_ids!(ids)
      cap = ::Collavre::TopicBranchService::MAX_BRANCH_COMMENTS
      raise ArgumentError, "comment_ids is required" if ids.empty?
      return if ids.size <= cap

      raise ArgumentError,
        "#{ids.size} messages requested but a branch copies at most #{cap}. " \
        "Select fewer messages, or branch more than once."
    end

    # Copying an approval prompt launders it. The branch copies content but not
    # `action`, so the copy no longer matches Comment.without_approval_action
    # and lands in exactly the agent-context queries the column exists to keep
    # it out of — the invariant survives a move, which keeps the column, but
    # not a copy. Refused here rather than silently dropped: a caller that
    # asked for 40 messages and got 39 has no way to learn which one is missing.
    #
    # Filtered through Comment#approval_action? rather than a SQL complement of
    # without_approval_action: the predicate is the documented single source of
    # truth, and a second copy of the condition could drift out of step with it.
    # validate_ids! has already capped the selection, so the load is bounded.
    #
    # Scoped to visible_to because this error names an id. Over the whole topic
    # it answers "is comment 4312 an approval prompt?" for a comment the caller
    # cannot read — a specific error where any other hidden id gets the generic
    # not-found — and it runs before the wrapped service checks feedback
    # permission, so read-only access is enough to ask. Restricted to what the
    # caller can already see, a hidden id falls through to the same not-found
    # every other unreadable id gets, and nothing distinguishes them. Approval
    # prompts stay unbranchable either way: the wrapped service's fetch is
    # visible_to as well, so an invisible one is refused there instead.
    def reject_approval_actions!(source, ids, user)
      blocked = source.comments.visible_to(user).where(id: ids).select(&:approval_action?).map(&:id)
      return if blocked.empty?

      raise ArgumentError,
        "#{blocked.join(', ')} #{blocked.one? ? 'is an approval prompt' : 'are approval prompts'} " \
        "and cannot be branched: a copy loses the approval action and becomes ordinary chat " \
        "history that agents read. Remove #{blocked.one? ? 'it' : 'them'} from comment_ids."
    end
  end
end
end
