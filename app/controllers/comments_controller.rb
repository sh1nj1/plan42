class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update ]

  def index
    per_page = params[:per_page].to_i
    per_page = 10 if per_page <= 0
    page = params[:page].to_i
    page = 1 if page <= 0

    scope = @creative.comments.order(created_at: :desc)
    @comments = scope.offset((page - 1) * per_page).limit(per_page).to_a
    pointer = CommentReadPointer.find_by(user: Current.user, creative: @creative)
    last_read_comment_id = pointer&.last_read_comment_id

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
    if @comment.save
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

  def show
    redirect_to creative_path(@creative, comment_id: @comment.id)
  end

  private

  def set_creative
    @creative = Creative.find(params[:creative_id]).effective_origin
  end

  def set_comment
    @comment = @creative.comments.find(params[:id])
  end

  def comment_params
    params.require(:comment).permit(:content)
  end
end
