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
    def call(comment_ids:, enforce_limit: true)
      comment_ids = Array(comment_ids).map(&:presence).compact.map(&:to_i)
      comment_ids = comment_ids.first(MAX_BRANCH_COMMENTS) if enforce_limit
      raise BranchError, I18n.t("collavre.comments.branch.no_selection") if comment_ids.empty?

      validate_permissions!
      originals = fetch_comments(comment_ids)

      Topic.transaction do
        @new_topic = create_branch_topic
        copy_comments(originals)
      end

      broadcast_topic_created

      @new_topic
    end

    private

    attr_reader :creative, :user, :source_topic, :name

    def validate_permissions!
      unless creative.has_permission?(user, :feedback)
        raise BranchError, I18n.t("collavre.comments.branch.not_authorized")
      end
    end

    def fetch_comments(comment_ids)
      scope = source_topic ? source_topic.comments.visible_to(user) : creative.comments.visible_to(user)
      comments = scope.where(id: comment_ids).order(:created_at).to_a
      if comments.length != comment_ids.length
        raise BranchError, I18n.t("collavre.comments.branch.comments_not_found")
      end
      comments
    end

    def create_branch_topic
      topic_name = name.presence || default_branch_name

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
          review_type: original.review_type,
          skip_default_user: true,
          skip_dispatch: true
        )

        # Remap quoted_comment_id if the quoted comment was also copied
        if original.quoted_comment_id && id_mapping[original.quoted_comment_id]
          new_comment.quoted_comment_id = id_mapping[original.quoted_comment_id]
        end

        new_comment.save!
        id_mapping[original.id] = new_comment.id

        # Share image blobs (no duplication of file data)
        original.images.each do |image|
          new_comment.images.attach(image.blob)
        end
      end
    end

    def broadcast_topic_created
      TopicsChannel.broadcast_to(
        creative,
        {
          action: "created",
          topic: { id: @new_topic.id, name: @new_topic.name, source_topic_id: @new_topic.source_topic_id },
          user_id: user.id
        }
      )
    end
  end
end
