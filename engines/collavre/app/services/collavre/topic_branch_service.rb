module Collavre
  class TopicBranchService
    class BranchError < StandardError; end

    MAX_BRANCH_COMMENTS = 100

    def initialize(creative:, user:, source_topic:, name: nil)
      @creative = creative
      @user = user
      @source_topic = source_topic
      @name = name
    end

    # Creates a new topic with copies of the selected comments.
    # Returns the new Topic.
    # enforce_limit: false bypasses MAX_BRANCH_COMMENTS for system-initiated
    # full-history copies (e.g. Drop Trigger) where the UI's selection cap
    # does not apply.
    # auto_select: false omits user_id from the topic-created broadcast so
    # background/system branches do not hijack the owner's current selection.
    # skip_approval_actions is reserved for system history copies that already
    # selected an approval-free set but must tolerate a row becoming an approval
    # prompt before the locked fetch. Interactive branches keep the default
    # all-or-nothing rejection.
    def call(comment_ids:, enforce_limit: true, auto_select: true, skip_approval_actions: false)
      comment_ids = Array(comment_ids).map(&:presence).compact.map(&:to_i)
      comment_ids = comment_ids.first(MAX_BRANCH_COMMENTS) if enforce_limit
      raise BranchError, I18n.t("collavre.comments.branch.no_selection") if comment_ids.empty?

      Topic.transaction do
        lock_source!
        validate_permissions!
        originals = fetch_comments(comment_ids)
        originals = originals.reject(&:approval_action?) if skip_approval_actions
        reject_approval_actions!(originals)
        @new_topic = create_branch_topic
        copy_comments(originals)
      end

      broadcast_topic_created(auto_select: auto_select)

      @new_topic
    end

    private

    attr_reader :creative, :user, :source_topic, :name

    def lock_source!
      return unless source_topic

      # The topic can move after a caller's preflight authorization. Pin its
      # current creative under the same lock that protects the comment fetch so
      # permissions and the branch destination cannot refer to stale state.
      source_topic.lock!
      @creative = source_topic.creative
    end

    def validate_permissions!
      unless creative.has_permission?(user, :feedback)
        raise BranchError, I18n.t("collavre.comments.branch.not_authorized")
      end
    end

    def fetch_comments(comment_ids)
      scope = source_topic ? source_topic.comments.visible_to(user) : creative.comments.visible_to(user)
      comments = scope.where(id: comment_ids).order(:created_at).lock.to_a
      if comments.length != comment_ids.length
        raise BranchError, I18n.t("collavre.comments.branch.comments_not_found")
      end
      comments
    end

    def reject_approval_actions!(comments)
      return unless comments.any?(&:approval_action?)

      raise BranchError, I18n.t("collavre.comments.branch.approval_action_not_branchable")
    end

    def create_branch_topic
      topic_name = name.presence || default_branch_name
      Topics::ReservedName.reject!(creative, topic_name, error_class: BranchError)

      creative.topics.create!(
        name: topic_name,
        user: user,
        source_topic_id: source_topic&.id
      )
    end

    def default_branch_name
      prefix = I18n.t("collavre.topics.branch_prefix")
      source_name = source_topic&.name || I18n.t("collavre.comments.topic_main", default: "All Messages")
      candidate = "#{prefix}:#{source_name}"

      existing = creative.topics.where("name LIKE ?", "#{Topic.sanitize_sql_like(candidate)}%").pluck(:name)
      return candidate unless existing.include?(candidate)

      counter = 2
      counter += 1 while existing.include?("#{candidate} #{counter}")
      "#{candidate} #{counter}"
    end

    def copy_comments(originals)
      id_mapping = {}

      originals.each do |original|
        new_comment = Comment.new(
          creative: creative,
          topic: @new_topic,
          user_id: original.user_id,
          content: original.content,
          private: original.private,
          # Carried with `private`, not separately from it: visible_to reads a
          # private comment for its author *and* its approver, so copying the
          # flag without the approver narrows who can see the copy. The user who
          # selected the message can be the approver rather than the author, and
          # would then get a branch reporting a message it cannot show them.
          approver_id: original.approver_id,
          review_type: original.review_type,
          skip_default_user: true,
          skip_dispatch: true
        )

        # Remap quoted_comment_id if the quoted comment was also copied
        if original.quoted_comment_id && id_mapping[original.quoted_comment_id]
          new_comment.quoted_comment_id = id_mapping[original.quoted_comment_id]
        end

        # Attach before validation so an image-only comment still satisfies the
        # Comment content-or-images invariant. Reuse the blobs without copying
        # file data, as the post-save loop did previously.
        new_comment.images.attach(original.images.map(&:blob)) if original.images.attached?

        new_comment.save!
        id_mapping[original.id] = new_comment.id
      end
    end

    def broadcast_topic_created(auto_select: true)
      payload = {
        action: "created",
        topic: { id: @new_topic.id, name: @new_topic.name, source_topic_id: @new_topic.source_topic_id }
      }
      payload[:user_id] = user.id if auto_select
      TopicsChannel.broadcast_to(creative, payload)
    end
  end
end
