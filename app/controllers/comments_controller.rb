class CommentsController < ApplicationController
  before_action :set_creative

  def index
    @comments = @creative.comments.order(created_at: :desc)
    render partial: "comments/list", locals: { comments: @comments }
  end

  def create
    @comment = @creative.comments.build(comment_params)
    @comment.user = Current.user
    if @comment.save
      render partial: "comments/comment", locals: { comment: @comment }, status: :created
    else
      render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @comment = @creative.comments.find(params[:id])
    if @comment.user == Current.user
      @comment.destroy
      head :no_content
    else
      render json: { error: I18n.t("comments.not_owner") }, status: :forbidden
    end
  end

  private

  def set_creative
    @creative = Creative.find(params[:creative_id])
  end

  def comment_params
    params.require(:comment).permit(:content)
  end
end
