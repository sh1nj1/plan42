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
    if last_read_comment_id && last_read_comment_id == @creative.comments.maximum(:id)
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
    response = handle_comment_commands(@comment)
    @comment.content = @comment.content + "\n\n" + response if response
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
    @comment = @creative.comments.find(params[:id])
  end

  def comment_params
    params.require(:comment).permit(:content)
  end

  def handle_comment_commands(comment)
    content = comment.content.to_s.strip
    return unless content.match?(/\A\/(?:calendar|cal)\b/)

    # Generalize: skip characters until first space; args are whatever follows
    args = content.sub(/\A\S+/, "").strip
    match = args.match(/\A(\d{4}-\d{2}-\d{2})(?:@(\d{2}:\d{2}))?(?:\s+(.*))?\z/)

    Rails.logger.debug("### Calendar command: #{match}, #{args}")
    return unless match

    date_str = match[1]
    time_str = match[2]
    memo = match[3]

    Rails.logger.debug("### Calendar command: #{date_str}, #{time_str}, #{memo}")
    if time_str
      start_time = Time.zone.parse("#{date_str} #{time_str}")
      end_time = start_time
    else
      start_time = Date.parse(date_str)
      end_time = start_time
    end

    Rails.logger.debug("### Calendar command 2: #{start_time}, #{end_time}")
    base_summary = comment.creative.effective_description(false, false)
    summary = memo.presence || base_summary&.to_plain_text
    calendar_id = comment.user&.calendar_id.presence || "primary"

    event =GoogleCalendarService.new(user: Current.user).create_event(
      calendar_id: calendar_id,
      start_time: start_time,
      end_time: end_time,
      summary: summary,
      description: creative_url(@creative, comment_id: comment.id),
      all_day: time_str.nil?
    )
    Rails.logger.debug("### Calendar command 4: #{calendar_id}, #{event.html_link}")
    "event created: #{event.html_link}"
  rescue StandardError => e
    Rails.logger.error("Calendar command failed: #{e.message}")
  end
end
