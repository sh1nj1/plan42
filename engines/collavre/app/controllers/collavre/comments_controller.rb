module Collavre
  class CommentsController < ApplicationController
    LEGACY_TOPIC_WATERMARK_KEY = "_legacy"
    include Collavre::Comments::CommentScoping
    include Collavre::Comments::ApprovalActions
    include Collavre::Comments::Conversion
    include Collavre::Comments::BatchOperations

    before_action :set_creative
    before_action :set_comment, only: [ :destroy, :show, :update, :convert, :approve, :deny, :update_action, :download_images, :remove_image ]

    def fullscreen
      # Render the creative index page with comments popup auto-opened in fullscreen.
      # This way the creative list loads behind the popup, so exiting fullscreen
      # doesn't require a page reload.
      @parent_creative = @creative
      @creatives = []
      @shared_list = @creative.all_shared_users
      @auto_fullscreen = true
      # Set params[:id] so the tree URL in creatives/index loads children of this
      # creative instead of the root list.
      params[:id] = @creative.id.to_s
      # Prepend creatives prefix so partials like 'add_button' resolve to collavre/creatives/_add_button
      lookup_context.prefixes.prepend "collavre/creatives"
      render "collavre/creatives/index"
    end

    def index
      Collavre::Comments::ListResponse.new(controller: self, creative: @creative).render
    end

    def create
      if @creative.archived?
        render json: { error: I18n.t("collavre.comments.archived_creative") }, status: :forbidden and return
      end

      unless @creative.has_permission?(Current.user, :feedback)
        render json: { error: I18n.t("collavre.comments.no_permission") }, status: :forbidden and return
      end

      comment_attributes = comment_params.except(:images)
      image_attachments = comment_params[:images]

      @comment = @creative.comments.build(comment_attributes)

      validate_topic_id!(@comment.topic_id) or return

      @comment.user = Current.user
      @comment.images.attach(image_attachments) if image_attachments.present?
      response = unless inbox_system_comment?
        ::Comments::CommandProcessor.new(comment: @comment, user: Current.user).call
      end
      if response.present?
        @comment.content = "#{@comment.content}\n\n#{response}"
        @comment.skip_dispatch = true
      end
      if @comment.save
        # Cross-post inbox inline replies to the original creative/topic
        InboxReplyService.call(@comment)

        # Dispatch is handled by Comment#after_create_commit callback
        @comment = Comment.with_attached_images.includes(:comment_reactions, :comment_versions, :selected_version).find(@comment.id)
        render partial: "collavre/comments/comment", locals: { comment: @comment, current_topic_id: current_topic_context }, status: :created
      else
        render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      if github_synced_content_comment?(@comment)
        render json: { error: I18n.t("collavre.comments.github_synced_readonly") }, status: :forbidden and return
      end

      if @comment.user == Current.user
        safe_params = comment_params.except(:quoted_comment_id, :quoted_text)
        validate_topic_id!(safe_params[:topic_id]) or return

        if update_comment(safe_params)
          @comment = Comment.with_attached_images.includes(:comment_reactions, :comment_versions, :selected_version).find(@comment.id)
          render partial: "collavre/comments/comment", locals: { comment: @comment, current_topic_id: current_topic_context }
        else
          render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
        end
      else
        render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden
      end
    end

    def destroy
      if github_synced_content_comment?(@comment)
        render json: { error: I18n.t("collavre.comments.github_synced_readonly") }, status: :forbidden and return
      end

      # @comment is set by before_action
      is_owner = @comment.user == Current.user
      is_admin = @creative.has_permission?(Current.user, :admin)
      is_creative_owner = @creative.user == Current.user

      if is_owner || is_admin || is_creative_owner
        # If admin/creative owner is deleting someone else's comment, send notification
        if (is_admin || is_creative_owner) && !is_owner && @comment.user.present? && !@comment.user.ai_user?
          inbox_creative = Creative.inbox_for(@comment.user)
          creative_path = Collavre::Engine.routes.url_helpers.creative_path(@creative, open_comments: true)
          creative_link = "[#{@creative.creative_snippet_markdown}](#{creative_path})"
          msg = I18n.t(
            "inbox.comment_deleted_by_admin",
            admin_name: Current.user.name,
            creative_snippet: creative_link,
            comment_content: @comment.content,
            locale: @comment.user.locale || "en"
          )
          system_topic = inbox_creative.system_topic(fallback_user: @comment.user)
          # Don't use quoted_comment here — the original comment is about to be
          # destroyed and would cascade-delete this inbox comment via
          # has_many :quoting_comments, dependent: :destroy.
          Comment.create!(
            creative: inbox_creative,
            topic: system_topic,
            content: msg,
            user: nil,
            skip_default_user: true
          )
        end

        @comment.destroy
        head :no_content
      else
        render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden
      end
    end



    def show
      redirect_to creative_path(@creative, comment_id: @comment.id)
    end

    def participants
      users = [ @creative.user ].compact + @creative.all_shared_users(:feedback).map(&:user)
      users = users.uniq
      user_data = users.map { |u| view_context.user_json(u, email: true, ai_user: true) }
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
      response.headers["Expires"] = "0"

      render json: {
        users: user_data,
        can_share: @creative.has_permission?(Current.user, :admin),
        can_comment: @creative.has_permission?(Current.user, :feedback),
        has_access: @creative.has_permission?(Current.user, :read)
      }
    end

    def commands
      unless @creative.has_permission?(Current.user, :read)
        head :forbidden and return
      end

      render json: CommandMenuService.new(user: Current.user, creative: @creative).items
    end

    def download_images
      images = @comment.images
      unless images.attached?
        head :not_found
        return
      end

      # Single image download by index
      if params[:index].present?
        image = images.to_a[params[:index].to_i]
        unless image
          head :not_found
          return
        end
        image.blob.open do |file|
          send_data file.read, filename: image.filename.to_s, type: image.content_type, disposition: "attachment"
        end
        return
      end

      # All images as zip
      require "zip"
      zip_filename = "images-comment-#{@comment.id}.zip"

      buffer = Zip::OutputStream.write_buffer do |zip|
        images.each do |image|
          zip.put_next_entry(image.filename.to_s)
          image.blob.open { |file| zip.write(file.read) }
        end
      end
      buffer.rewind

      send_data buffer.read, filename: zip_filename, type: "application/zip", disposition: "attachment"
    end

    def remove_image
      images = @comment.images
      index = params[:index].to_i
      image = images.to_a[index]

      unless image
        head :not_found
        return
      end

      unless @comment.user_id == Current.user.id || Current.user.system_admin?
        head :forbidden
        return
      end

      image.purge
      head :ok
    end

    private

    def github_synced_content_comment?(comment)
      return false unless comment.topic&.name == Collavre::Creative::CONTENT_TOPIC_NAME
      comment.creative&.github_markdown?
    end

    def comment_params
      params.require(:comment).permit(:content, :private, :topic_id, :quoted_comment_id, :quoted_text, :review_type, images: [])
    end

    def current_topic_context
      params[:topic_id].presence || params.dig(:comment, :topic_id).presence
    end

    def inbox_system_comment?
      @creative.inbox? && @comment.topic&.name == Creative::SYSTEM_TOPIC_NAME
    end

    def validate_topic_id!(topic_id)
      return true if topic_id.blank? || @creative.topics.where(id: topic_id).exists?
      render json: { error: I18n.t("collavre.comments.invalid_topic") }, status: :unprocessable_entity
      false
    end

    def update_comment(attributes)
      return @comment.update(attributes) unless attributes.key?(:topic_id)

      attributes = attributes.dup
      topic_id = attributes.delete(:topic_id)
      Comment.transaction do
        CommentMoveService.new(creative: @creative, user: Current.user).call(
          comment_ids: [ @comment.id ], target_topic_id: topic_id
        )
        @comment.reload.update(attributes)
      end
    rescue CommentMoveService::MoveError => e
      @comment.errors.add(:topic, e.message)
      false
    end
  end
end
