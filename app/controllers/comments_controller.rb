class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update, :convert, :approve, :update_action ]

  def index
    per_page = params[:per_page].to_i
    per_page = 10 if per_page <= 0
    page = params[:page].to_i
    page = 1 if page <= 0

    scope = @creative.comments.where(
      "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
      false,
      Current.user.id,
      Current.user.id
    )
    scope = scope.with_attached_images
    target_page = page
    if params[:comment_id].present?
      target_comment = scope.find_by(id: params[:comment_id])
      if target_comment
        newer_count = scope.where(
          "comments.created_at > ? OR (comments.created_at = ? AND comments.id > ?)",
          target_comment.created_at,
          target_comment.created_at,
          target_comment.id
        ).count
        target_page = (newer_count / per_page) + 1
      end
    end
    if params[:search].present?
      search_term = ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip.downcase)
      scope = scope.where("LOWER(comments.content) LIKE ?", "%#{search_term}%")
    end
    scope = scope.order(created_at: :desc)
    page = target_page
    @comments = scope.offset((page - 1) * per_page).limit(per_page).to_a
    pointer = CommentReadPointer.find_by(user: Current.user, creative: @creative)
    last_read_comment_id = pointer&.last_read_comment_id
    max_id = scope.maximum(:id)
    if last_read_comment_id && last_read_comment_id == max_id
      last_read_comment_id = nil
    end

    comments_for_render = page <= 1 ? @comments.reverse : @comments

    response.set_header("X-Comments-Page", page)
    if page <= 1 || params[:comment_id].present?
      render partial: "comments/list", locals: { comments: comments_for_render, creative: @creative, last_read_comment_id: last_read_comment_id }
    else
      render partial: "comments/comment", collection: comments_for_render, as: :comment
    end
  end

  def create
    unless @creative.has_permission?(Current.user, :feedback)
      render json: { error: I18n.t("comments.no_permission") }, status: :forbidden and return
    end

    comment_attributes = comment_params.except(:images)
    image_attachments = comment_params[:images]

    @comment = @creative.comments.build(comment_attributes)
    @comment.user = Current.user
    @comment.images.attach(image_attachments) if image_attachments.present?
    response = Comments::CommandProcessor.new(comment: @comment, user: Current.user).call
    @comment.content = "#{@comment.content}\n\n#{response}" if response.present?
    if @comment.save
      # Trigger AI responder for any @mention at the start
      if @comment.content.match?(/\A@/)
        Comments::AiResponderJob.perform_later(@comment.id, @creative.id)
      end
      @comment = Comment.with_attached_images.find(@comment.id)
      render partial: "comments/comment", locals: { comment: @comment }, status: :created
    else
      render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @comment.user == Current.user
      if @comment.update(comment_params)
        @comment = Comment.with_attached_images.find(@comment.id)
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
              creative_snippet: @creative.creative_snippet
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
        comment.update!(creative: target_origin)
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
    params.require(:comment).permit(:content, :private, images: [])
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
