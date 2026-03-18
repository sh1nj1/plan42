module Collavre
  class CommentsController < ApplicationController
    include Collavre::Comments::ApprovalActions
    include Collavre::Comments::Conversion
    include Collavre::Comments::BatchOperations

    before_action :set_creative
    before_action :set_comment, only: [ :destroy, :show, :update, :convert, :approve, :update_action ]

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
      limit = 20

      visible_scope = @creative.comments.where(
        "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
        false,
        Current.user.id,
        Current.user.id
      )
      scope = visible_scope.with_attached_images.includes(:topic, :comment_reactions, :comment_versions)

      if params[:search].present?
        search_term = ActiveRecord::Base.sanitize_sql_like(params[:search].to_s.strip.downcase)
        scope = scope.where("LOWER(comments.content) LIKE ?", "%#{search_term}%")
      end

      # Filter by topic
      # Logic:
      # 1. Prefer params[:topic_id] if explicit.
      # 2. If deep linking (around_comment_id), infer from target comment if valid.
      # 3. Default to nil (Main).

      effective_topic_id = params[:topic_id].presence

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
      if effective_topic_id.present?
        scope = scope.where(topic_id: effective_topic_id)
      else
        # Main view: exclude comments from archived topics
        archived_topic_ids = @creative.topics.archived.pluck(:id)
        scope = scope.where.not(topic_id: archived_topic_ids) if archived_topic_ids.any?
      end

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
        render partial: "collavre/comments/comment",
               collection: @comments,
               as: :comment,
               locals: { read_receipts: read_receipts, present_user_ids: present_user_ids, current_topic_id: effective_topic_id }
      else
        render partial: "collavre/comments/list", locals: {
          comments: @comments,
          creative: @creative,
          read_receipts: read_receipts,
          present_user_ids: present_user_ids,
          current_topic_id: effective_topic_id
        }
      end
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

      if @comment.topic_id.present? && !@creative.topics.where(id: @comment.topic_id).exists?
        render json: { error: I18n.t("collavre.comments.invalid_topic") }, status: :unprocessable_entity and return
      end

      @comment.user = Current.user
      @comment.images.attach(image_attachments) if image_attachments.present?
      response = ::Comments::CommandProcessor.new(comment: @comment, user: Current.user).call
      @comment.content = "#{@comment.content}\n\n#{response}" if response.present?
      if @comment.save

        # Dispatch system event
        unless @comment.private? || response.present?
          begin
            ::SystemEvents::Dispatcher.dispatch("comment_created", {
              comment: {
                id: @comment.id,
                content: @comment.content,
                user_id: @comment.user_id,
                from_ai: @comment.user&.searchable? || false,
                quoted_comment_id: @comment.quoted_comment_id
              }.compact,
              creative: {
                id: @creative.id,
                description: @creative.description
              },
              topic: {
                id: @comment.topic_id
              },
              chat: {
                content: @comment.content
              }
            })
          rescue => e
            Rails.logger.error(
              "[SystemEvents] Dispatch failed for comment #{@comment.id}: " \
              "#{e.class} #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
            )
          end
        end
        @comment = Comment.with_attached_images.includes(:comment_reactions, :comment_versions, :selected_version).find(@comment.id)
        render partial: "collavre/comments/comment", locals: { comment: @comment, current_topic_id: current_topic_context }, status: :created
      else
        render json: { errors: @comment.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      if @comment.user == Current.user
        safe_params = comment_params.except(:quoted_comment_id, :quoted_text)
        if safe_params[:topic_id].present? && !@creative.topics.where(id: safe_params[:topic_id]).exists?
          render json: { error: I18n.t("collavre.comments.invalid_topic") }, status: :unprocessable_entity and return
        end

        if @comment.update(safe_params)
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
        render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden
      end
    end



    def show
      redirect_to creative_path(@creative, comment_id: @comment.id)
    end

    def participants
      users = [ @creative.user ].compact + @creative.all_shared_users(:feedback).map(&:user)
      users = users.uniq
      user_data = users.map do |u|
        {
          id: u.id,
          email: u.email,
          name: u.display_name,
          avatar_url: view_context.user_avatar_url(u, size: 20),
          default_avatar: !u.avatar.attached? && u.avatar_url.blank?,
          initial: u.display_name[0].upcase,
          ai_user: u.ai_user?
        }
      end
      render json: {
        users: user_data,
        can_share: @creative.has_permission?(Current.user, :admin)
      }
    end

    def commands
      unless @creative.has_permission?(Current.user, :read)
        head :forbidden and return
      end

      render json: CommandMenuService.new(user: Current.user).items
    end


    private

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
      unless @creative.has_permission?(Current.user, :read)
        render json: { error: I18n.t("collavre.creatives.errors.no_permission") }, status: :forbidden
      end
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
      params.require(:comment).permit(:content, :private, :topic_id, :quoted_comment_id, :quoted_text, :review_type, images: [])
    end

    def current_topic_context
      params[:topic_id].presence || params.dig(:comment, :topic_id).presence
    end
  end
end
