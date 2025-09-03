class CommentsController < ApplicationController
  before_action :set_creative
  before_action :set_comment, only: [ :destroy, :show, :update, :convert ]

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
    @comment.content = "#{@comment.content}\n\n#{response}" if response.present?
    if @comment.save
      trigger_gemini_response(@comment) if @comment.content.match?(/\A@gemini\b/i)
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
        MarkdownImporter.import(@comment.content, parent: @creative, user: @comment.user, create_root: true)
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

  def trigger_gemini_response(comment)
    content = comment.content.sub(/\A@gemini\s*/i, "").strip
    return if content.blank?
    messages = []
    markdown = helpers.render_creative_tree_markdown([ @creative ], 1, true)
    messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }
    @creative.comments.order(:created_at).each do |c|
      role = c.user_id ? "user" : "model"
      text = c.content.sub(/\A@gemini\s*/i, "")
      messages << { role: role, parts: [ { text: text } ] }
    end
    reply = @creative.comments.create!(content: "...", user: comment.user)
    Rails.logger.debug("### Gemini chat: #{messages}")
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        accumulator = "gemini: "
        GeminiChatClient.new.chat(messages) do |delta|
          next if delta.blank?
          accumulator += delta
          begin
            reply.update!(content: accumulator)
            Rails.logger.debug("### Gemini chat: #{accumulator}")
          rescue StandardError => e
            Rails.logger.error("Gemini reply update failed: #{e.class} #{e.message}")
          end
        end
      end
    end
  end

  def handle_comment_commands(comment)
    handle_calendar_command(comment)
  rescue StandardError => e
    Rails.logger.error("Calendar command failed: #{e.message}")
    e.message
  end

  def handle_calendar_command(comment)
    content = comment.content.to_s.strip
    return unless content.match?(/\A\/(?:calendar|cal)\b/)
    # Generalize: skip characters until first space; args are whatever follows
    args = content.sub(/\A\S+/, "").strip
    # Support keyword 'today' (case-insensitive) as the date
    if args.match?(/\Atoday\b/i)
      args = args.sub(/\A(today)\b/i, Time.zone.today.to_s)
    end
    # Support: 'YYYY-MM-DD@HH:MM memo', 'YYYY-MM-DD memo', or '@HH:MM memo' (date defaults to today)
    match = args.match(/\A(?:(\d{4}-\d{2}-\d{2}))?(?:@(\d{2}:\d{2}))?(?:\s+(.*))?\z/)

    Rails.logger.debug("### Calendar command: #{match}, #{args}")
    return unless match && (match[1].present? || match[2].present?)

    date_str = match[1]
    time_str = match[2]
    memo = match[3]

    # TODO: use user's timezone (Time.zone == UTC)
    timezone = Time.zone
    Rails.logger.debug("### Calendar command: #{timezone.tzinfo.name} #{date_str}, #{time_str}, #{memo}")
    if time_str
      date_for_time = date_str.presence || timezone.today.to_s
      start_time = timezone.parse("#{date_for_time} #{time_str}")
      end_time = start_time
    else
      # All-day: date is required; if somehow missing, default to today
      start_time = Date.parse(date_str.presence || timezone.today.to_s)
      end_time = start_time
    end

    base_summary = comment.creative.effective_description(false, false)
    summary = memo.presence || base_summary&.to_plain_text
    calendar_id = comment.user&.calendar_id.presence || "primary"

    event = GoogleCalendarService.new(user: Current.user).create_event(
      calendar_id: calendar_id,
      start_time: start_time,
      end_time: end_time,
      summary: summary,
      description: creative_url(@creative, comment_id: comment.id),
      timezone: timezone.tzinfo.name,
      all_day: time_str.nil?,
      creative: @creative
    )
    "event created: #{event.html_link}"
  end
end
