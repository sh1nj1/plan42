class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update, :convert ]

  def index
    per_page = params[:per_page].to_i
    per_page = 10 if per_page <= 0
    page = params[:page].to_i
    page = 1 if page <= 0

    scope = @creative.comments.where("comments.private = ? OR comments.user_id = ?", false, Current.user.id)
                              .order(created_at: :desc)
    @comments = scope.offset((page - 1) * per_page).limit(per_page).to_a
    pointer = CommentReadPointer.find_by(user: Current.user, creative: @creative)
    last_read_comment_id = pointer&.last_read_comment_id
    max_id = scope.maximum(:id)
    if last_read_comment_id && last_read_comment_id == max_id
      last_read_comment_id = nil
    end

    if page <= 1
      render partial: "comments/list", locals: { comments: @comments.reverse, creative: @creative, last_read_comment_id: last_read_comment_id }
    else
      render partial: "comments/comment", collection: @comments, as: :comment
    end
  end

  def create
    @comment = @creative.comments.build(comment_params)
    @comment.user = Current.user
    unless @creative.has_permission?(Current.user, :feedback)
      render json: { error: I18n.t("comments.no_permission") }, status: :forbidden and return
    end
    response = Comments::CommandProcessor.new(comment: @comment, user: Current.user).call
    @comment.content = "#{@comment.content}\n\n#{response}" if response.present?
    if @comment.save
      if @comment.content.match?(/\A@gemini\b/i)
        Comments::GeminiResponderJob.perform_later(@comment.id, @creative.id)
      end
      render partial: "comments/comment", locals: { comment: @comment }, status: :created
    else
      render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @comment.user == Current.user
      if @comment.update(comment_params)
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
    if @comment.user == Current.user
      @comment.destroy
      head :no_content
    else
      render json: { error: I18n.t("comments.not_owner") }, status: :forbidden
    end
  end

  def convert
    if @comment.user == Current.user
      created_creatives = MarkdownImporter.import(
        @comment.content,
        parent: @creative,
        user: @comment.user,
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
    else
      render json: { error: I18n.t("comments.not_owner") }, status: :forbidden
    end
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

  private

  def set_creative
    @creative = Creative.find(params[:creative_id]).effective_origin
  end

  def set_comment
    @comment = @creative.comments
                           .where("comments.private = ? OR comments.user_id = ?", false, Current.user.id)
                           .find(params[:id])
  end

  def comment_params
    params.require(:comment).permit(:content, :private)
  end

  def build_convert_system_message(creative)
    title = creative.description&.to_plain_text.to_s.strip
    title = I18n.t("comments.convert_system_message_default_title") if title.blank?
    url = creative_path(creative)
    I18n.t("comments.convert_system_message", title: title, url: url)
  end
end
