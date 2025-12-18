class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update, :convert, :approve, :update_action ]

  def index
    limit = 20

    visible_scope = @creative.comments.where(
      "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
      false,
      Current.user.id,
      Current.user.id
    )
    scope = visible_scope.with_attached_images.includes(:topic)

    if params[:search].present?
      search_term = ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip.downcase)
      scope = scope.where("LOWER(comments.content) LIKE ?", "%#{search_term}%")
    end

    # Filter by topic
    # Logic:
    # 1. Prefer params[:topic_id] if explicit.
    # 2. If deep linking (around_comment_id), infer from target comment if valid.
    # 3. Default to nil (Main).

    effective_topic_id = params[:topic_id]

    if params[:around_comment_id].present?
      target_id = params[:around_comment_id].to_i
      # Ensure target is visible and belongs to this creative
      target_comment = visible_scope.find_by(id: target_id)

      if target_comment
        effective_topic_id = target_comment.topic_id
        # Inform frontend about the topic switch
        response.headers["X-Topic-Id"] = effective_topic_id.to_s
      end
    end

    # Apply the Topic Filter
    scope = scope.where(topic_id: effective_topic_id) if effective_topic_id.present?

    # Default order: Newest first (created_at DESC)
    # This matches the column-reverse layout where the first item in the list is the visual bottom (Newest).
    scope = scope.order(created_at: :desc)


    @comments = if params[:around_comment_id].present?
      # Deep linking: Load context around a specific comment
      target_id = params[:around_comment_id].to_i

      # Newer messages have HIGHER IDs.
      # Older messages have LOWER IDs.

      # Newer bundle (including target): ID >= target_id
      newer_bundle = scope.where("comments.id >= ?", target_id).reorder(created_at: :asc).limit(limit / 2 + 1)

      # Older bundle: ID < target_id
      older_bundle = scope.where("comments.id < ?", target_id).limit(limit / 2)

      # Combine: [Newer (ASC) ... Target ... Older (DESC)]
      # We need final output to be ASC due to restored view logic: [Oldest ... Target ... Newest]
      (older_bundle.to_a.reverse + newer_bundle.to_a).uniq
    elsif params[:after_id].present? && params[:before_id].present?
        # Invalid state, prioritize before (loading older history)
        scope.where("comments.id < ?", params[:before_id].to_i).limit(limit).to_a.reverse
    elsif params[:before_id].present?
      # Load OLDER messages (lower IDs)
      # Visually scrolling UP
      scope.where("comments.id < ?", params[:before_id].to_i).limit(limit).to_a.reverse
    elsif params[:after_id].present?
      # Load NEWER messages (higher IDs)
      # Visually scrolling DOWN
      # We want the ones immediately *after* the current newest.
      # Since default sort is DESC (Newest first), "after" means id > after_id.
      # But standard DESC query would give us the VERY Newest.
      # We want the ones just above `after_id`.

      # Use reorder(ASC) to get the ones immediately larger than after_id, then reverse back to DESC.
      scope.where("comments.id > ?", params[:after_id].to_i).reorder(created_at: :asc).limit(limit)
    else
      # Initial Load (Latest messages)
      scope.limit(limit).to_a.reverse
    end

    present_user_ids = CommentPresenceStore.list(@creative.id)

    read_receipts = {}
    if @comments.any?
      # Fetch all read pointers for this creative that point to comments in the current list
      # We only care about pointers that match the IDs of the comments we are displaying?
      # Or rather, we want to show the 'line' on the comment that matches the pointer.

      # Optimization: Fetch all pointers for participants of this creative.
      # Scoped to the creative.
      pointers = CommentReadPointer.where(creative: @creative)
                                   .where.not(last_read_comment_id: nil)
                                   .includes(user: { avatar_attachment: :blob })

      # Fetch all visible IDs for correct read-receipt placement transparency
      # Only map read receipts to PUBLIC comments.
      # Users who read private comments will appear on the nearest preceding public comment.
      public_ids = @creative.comments.where(private: false).order(id: :asc).pluck(:id)

      pointers.each do |pointer|
        effective_id = pointer.effective_comment_id(public_ids)
        if effective_id
          read_receipts[effective_id] ||= []
          read_receipts[effective_id] << pointer.user
        end
      end
    end

    if params[:after_id].present? || params[:before_id].present?
      render partial: "comments/comment",
             collection: @comments,
             as: :comment,
             locals: { read_receipts: read_receipts, present_user_ids: present_user_ids }
    else
      render partial: "comments/list", locals: {
        comments: @comments,
        creative: @creative,
        read_receipts: read_receipts,
        present_user_ids: present_user_ids
      }
    end
  end

  def create
    unless @creative.has_permission?(Current.user, :feedback)
      render json: { error: I18n.t("comments.no_permission") }, status: :forbidden and return
    end

    comment_attributes = comment_params.except(:images)
    image_attachments = comment_params[:images]

    @comment = @creative.comments.build(comment_attributes)

    if @comment.topic_id.present? && !@creative.topics.where(id: @comment.topic_id).exists?
      render json: { error: I18n.t("comments.invalid_topic") }, status: :unprocessable_entity and return
    end

    @comment.user = Current.user
    @comment.images.attach(image_attachments) if image_attachments.present?
    response = Comments::CommandProcessor.new(comment: @comment, user: Current.user).call
    @comment.content = "#{@comment.content}\n\n#{response}" if response.present?
    if @comment.save

      # Dispatch system event
      SystemEvents::Dispatcher.dispatch("comment_created", {
        comment: {
          id: @comment.id,
          content: @comment.content,
          user_id: @comment.user_id
        },
        creative: {
          id: @creative.id,
          description: @creative.description
        },
        chat: {
          content: @comment.content
        }
      }) unless @comment.private?
      @comment = Comment.with_attached_images.includes(:topic).find(@comment.id)
      render partial: "comments/comment", locals: { comment: @comment }, status: :created
    else
      render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @comment.user == Current.user
      safe_params = comment_params
      if safe_params[:topic_id].present? && !@creative.topics.where(id: safe_params[:topic_id]).exists?
        render json: { error: I18n.t("comments.invalid_topic") }, status: :unprocessable_entity and return
      end

      if @comment.update(safe_params)
        @comment = Comment.with_attached_images.includes(:topic).find(@comment.id)
        render partial: "comments/comment", locals: { comment: @comment }
      else
        render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
      end
    else
      render json: { error: I18n.t("comments.not_owner") }, status: :forbidden
    end
  end

  def destroy
    # @comment is set by before_action
    is_owner = @comment.user == Current.user
    is_admin = @creative.has_permission?(Current.user, :admin)
    is_creative_owner = @creative.user == Current.user

    if is_owner || is_admin || is_creative_owner
      # If admin/creative owner is deleting someone else's comment, send notification
      if (is_admin || is_creative_owner) && !is_owner && @comment.user.present? && !@comment.user.ai_user?
        if @comment.user.present?
          InboxItem.create!(
            owner: @comment.user,
            creative: @creative,
            comment: @comment,
            message_key: "inbox.comment_deleted_by_admin",
            message_params: {
              admin_name: Current.user.name,
              creative_snippet: @creative.creative_snippet,
              comment_content: @comment.content
            },
            link: creative_path(@creative)
          )
        end
      end

      @comment.destroy
      head :no_content
    else
      render json: { error: I18n.t("comments.not_owner") }, status: :forbidden
    end
  end

  def convert
    unless can_convert_comment?
      render json: { error: I18n.t("comments.convert_not_allowed") }, status: :forbidden and return
    end

    created_creatives = MarkdownImporter.import(
      @comment.content,
      parent: @creative,
      user: @creative.user,
      create_root: true
    )

    primary_creative = created_creatives.first
    system_message = build_convert_system_message(primary_creative) if primary_creative

    @comment.destroy

    if system_message.present?
      Current.set(session: nil) do
        @creative.comments.create!(content: system_message, user: nil)
      end
    end

    head :no_content
  end

  def approve
    unless @comment.approver == Current.user
      render json: { error: I18n.t("comments.approve_not_allowed") }, status: :forbidden and return
    end

    begin
      Comments::ActionExecutor.new(comment: @comment, executor: Current.user).call
      @comment.reload
      render partial: "comments/comment", locals: { comment: @comment }
    rescue Comments::ActionExecutor::ExecutionError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end
  end

  def update_action
    unless @comment.approver == Current.user
      render json: { error: I18n.t("comments.approve_not_allowed") }, status: :forbidden and return
    end

    action_payload = params.dig(:comment, :action)
    if action_payload.blank?
      render json: { error: I18n.t("comments.approve_missing_action") }, status: :unprocessable_entity and return
    end

    validator = Comments::ActionValidator.new(comment: @comment)
    parsed_payload = validator.validate!(action_payload)
    normalized_action = JSON.pretty_generate(parsed_payload)

    executed_error = false
    update_success = false
    approver_mismatch_error = false

    @comment.with_lock do
      @comment.reload

      if @comment.approver != Current.user
        approver_mismatch_error = true
      elsif @comment.action_executed_at.present?
        executed_error = true
      else
        update_success = @comment.update(action: normalized_action)
      end
    end

    if approver_mismatch_error
      render json: { error: I18n.t("comments.approve_not_allowed") }, status: :forbidden
    elsif executed_error
      render json: { error: I18n.t("comments.approve_already_executed") }, status: :unprocessable_entity
    elsif update_success
      render partial: "comments/comment", locals: { comment: @comment }
    else
      error_message = @comment.errors.full_messages.to_sentence.presence || I18n.t("comments.action_update_error")
      render json: { error: error_message }, status: :unprocessable_entity
    end
  rescue Comments::ActionValidator::ValidationError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def show
    redirect_to creative_path(@creative, comment_id: @comment.id)
  end

  def participants
    users = [ @creative.user ].compact + @creative.all_shared_users(:feedback).map(&:user)
    users = users.uniq
    data = users.map do |u|
      {
        id: u.id,
        email: u.email,
        name: u.display_name,
        avatar_url: view_context.user_avatar_url(u, size: 20),
        default_avatar: !u.avatar.attached? && u.avatar_url.blank?,
        initial: u.display_name[0].upcase
      }
    end
    render json: data
  end

  def move
    comment_ids = Array(params[:comment_ids]).map(&:presence).compact.map(&:to_i)
    if comment_ids.empty?
      render json: { error: I18n.t("comments.move_no_selection") }, status: :unprocessable_entity and return
    end

    target_creative = Creative.find_by(id: params[:target_creative_id])
    if target_creative.nil?
      render json: { error: I18n.t("comments.move_invalid_target") }, status: :unprocessable_entity and return
    end

    target_origin = target_creative.effective_origin

    unless @creative.has_permission?(Current.user, :feedback) && target_origin.has_permission?(Current.user, :feedback)
      render json: { error: I18n.t("comments.move_not_allowed") }, status: :forbidden and return
    end

    scope = @creative.comments.where(
      "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
      false,
      Current.user.id,
      Current.user.id
    )

    comments = scope.where(id: comment_ids).to_a

    if comments.length != comment_ids.length
      render json: { error: I18n.t("comments.move_not_allowed") }, status: :forbidden and return
    end

    ActiveRecord::Base.transaction do
      comments.each do |comment|
        next if comment.creative_id == target_origin.id

        original_creative = comment.creative
        comment.update!(creative: target_origin, topic_id: nil)
        broadcast_move_removal(comment, original_creative)
      end
    end

    Comment.broadcast_badges(@creative)
    Comment.broadcast_badges(target_origin) unless target_origin == @creative

    render json: { success: true }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence.presence || I18n.t("comments.move_error") }, status: :unprocessable_entity
  end

  private

  def set_creative
    @creative = Creative.find(params[:creative_id]).effective_origin
  end

  def set_comment
    @comment = @creative.comments
                           .where(
                             "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
                             false,
                             Current.user.id,
                             Current.user.id
                           )
                           .find(params[:id])
  end

  def comment_params
    params.require(:comment).permit(:content, :private, :topic_id, images: [])
  end

  def can_convert_comment?
    @comment.user == Current.user || @creative.has_permission?(Current.user, :admin)
  end

  def broadcast_move_removal(comment, original_creative)
    return if comment.private?

    Turbo::StreamsChannel.broadcast_remove_to(
      [ original_creative, :comments ],
      target: view_context.dom_id(comment)
    )
  end

  def build_convert_system_message(creative)
    title = helpers.strip_tags(creative.description).to_s.strip
    title = I18n.t("comments.convert_system_message_default_title") if title.blank?
    url = creative_path(creative)
    I18n.t("comments.convert_system_message", title: title, url: url)
  end
end
