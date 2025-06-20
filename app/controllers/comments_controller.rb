class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update ]

  def index
    @comments = @creative.comments.order(created_at: :asc)
    render partial: "comments/list", locals: { comments: @comments, creative: @creative }
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
