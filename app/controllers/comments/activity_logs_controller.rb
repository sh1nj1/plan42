class Comments::ActivityLogsController < ApplicationController
  before_action :set_comment
  before_action :ensure_permission

  def show
    @activity_logs = @comment.activity_logs.order(created_at: :desc)
    render partial: "comments/activity_log_details", locals: { activity_logs: @activity_logs, comment: @comment }
  end

  private

  def set_comment
    @comment = Comment.find(params[:comment_id])
  end

  def ensure_permission
    # Ensure user can read the creative the comment belongs to
    unless @comment.creative.has_permission?(Current.user, :read)
      head :forbidden
    end
  end
end
