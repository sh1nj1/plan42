class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Collavre app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  # allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy request_permission parent_suggestions slide_view ]

  def index
    # 권한 캐시: 요청 내 CreativeShare 모두 메모리에 올림
    Current.creative_share_cache = CreativeShare.where(user: Current.user).index_by(&:creative_id)
    @expanded_state_map = CreativeExpandedState.where(user_id: Current.user.id, creative_id: params[:id]).first&.expanded_status || {}
    if params[:comment] == "true"
      # 코멘트가 있는 creative만, 코멘트 최신 업데이트 순
      @creatives = Creative
        .joins(:comments)
        .where.not(comments: { id: nil })
        .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
        .uniq(&:id)
      @creatives = @creatives.sort_by { |c| c.comments.maximum(:updated_at) || c.updated_at }.reverse
      @parent_creative = nil
    elsif params[:search].present?
      if params[:simple].present?
        @creatives = Creative
                       .joins(:rich_text_description)
                       .where("action_text_rich_texts.body LIKE :q", q: "%#{params[:search]}%")
                       .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
      elsif params[:id].present?
        base_creative = Creative.find_by(id: params[:id]).effective_origin
        if base_creative
          subtree_ids = base_creative.subtree_ids
          @creatives = Creative
                        .joins(:rich_text_description)
                        .left_joins(:comments) # Include comments to allow searching in them
                        .where(id: subtree_ids)
                        .where("action_text_rich_texts.body LIKE :q OR comments.content LIKE :q", q: "%#{params[:search]}%")
                        .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
          @parent_creative = base_creative
        else
          @creatives = []
          @parent_creative = nil
        end
      else
        @creatives = Creative.joins(:rich_text_description)
                             .left_joins(:comments) # Include comments to allow searching in them
                             .where("action_text_rich_texts.body LIKE :q OR comments.content LIKE :q", q: "%#{params[:search]}%")
                             .where(origin_id: nil)
                             .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
        @parent_creative = nil
      end
    elsif params[:id]
      creative = Creative.where(id: params[:id])
                   .order(:sequence)
                          .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
                           .first
      @parent_creative = creative
      @creatives = creative.children_with_permission(Current.user, :read) if creative
    else
      @creatives = Creative.where(user: Current.user).roots
      @parent_creative = nil
    end
    # 공유 리스트 로직: 자신과 모든 ancestor에서 공유된 사용자 수집
    if (@shared_creative = @parent_creative || @creatives&.first)
      @shared_list = @shared_creative.all_shared_users
    end

    if params[:tags].present?
      tag_ids = Array(params[:tags]).map(&:to_s)
      roots = @creatives || []
      progress_values = roots.map { |c| c.progress_for_tags(tag_ids) }.compact
      if progress_values.any?
        @overall_progress = progress_values.sum.to_f / progress_values.size
      else
        @overall_progress = 0
      end
    end

    respond_to do |format|
      format.html
      format.json do
        if params[:simple].present?
          render json: @creatives.map { |c| { id: c.id, description: c.effective_origin.description.to_plain_text } }
        else
          render json: @creatives.map { |c| { id: c.id, description: c.effective_description } }
        end
      end
    end
  end

  def show
    respond_to do |format|
      redirect_options = { id: @creative.id }
      redirect_options[:comment_id] = params[:comment_id] if params[:comment_id].present?
      format.html { redirect_to creatives_path(redirect_options) }
      format.json do
        root = params[:root_id] ? Creative.find_by(id: params[:root_id]) : nil
        depth = if root
                  (@creative.ancestors.count - root.ancestors.count) + 1
        else
                  @creative.ancestors.count + 1
        end
        render json: {
          id: @creative.id,
          description: @creative.effective_description,
          origin_id: @creative.origin_id,
          parent_id: @creative.parent_id,
          progress: @creative.progress,
          depth: depth,
          prompt: @creative.prompt_for(Current.user),
          prompt_comment_id: @creative.prompt_comment_for(Current.user)&.id
        }
      end
    end
  end

  def slide_view
    @slide_ids = []
    @root_depth = @creative.ancestors.count
    build_slide_ids(@creative)
    render layout: "slide"
  end

  def new
    @creative = Creative.new
    if params[:parent_id].present?
      @parent_creative = Creative.find_by(id: params[:parent_id])
      @creative.parent = @parent_creative if @parent_creative
    end
    if params[:child_id].present?
      @child_creative = Creative.find_by(id: params[:child_id])
    end
    if params[:after_id].present?
      @after_creative = Creative.find_by(id: params[:after_id])
    end
  end

  def create
    @creative = Creative.new(creative_params)
    if @creative.parent
      @creative.user = @creative.parent.user
    else
      @creative.user = Current.user
    end

    # Rebuild @child_creative from params if present
    if params[:child_id].present?
      @child_creative = Creative.find_by(id: params[:child_id])
    end

    if @creative.save
      @child_creative.update(parent: @creative) if @child_creative
      if params[:before_id].present?
        before_creative = Creative.find_by(id: params[:before_id])
        if before_creative && before_creative.parent_id == @creative.parent_id
          siblings = @creative.parent ? @creative.parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
          siblings.delete(@creative)
          index = siblings.index(before_creative) || 0
          siblings.insert(index, @creative)
          siblings.each_with_index { |c, idx| c.update_column(:sequence, idx) }
        end
      elsif params[:after_id].present?
        after_creative = Creative.find_by(id: params[:after_id])
        if after_creative && after_creative.parent_id == @creative.parent_id
          siblings = @creative.parent ? @creative.parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
          siblings.delete(@creative)
          index = siblings.index(after_creative) || -1
          siblings.insert(index + 1, @creative)
          siblings.each_with_index { |c, idx| c.update_column(:sequence, idx) }
        end
      end
      if params[:tags].present?
        Array(params[:tags]).each do |tag_id|
          @creative.tags.create(label_id: tag_id)
        end
      end
      render json: { id: @creative.id }
    else
      render json: { errors: @creative.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def parent_suggestions
    suggestions = GeminiParentRecommender.new.recommend(@creative)
    render json: suggestions
  end

  def edit
    if params[:inline]
      render partial: "form", locals: { creative: @creative }
    end
  end

  def update
    respond_to do |format|
      permitted = creative_params.to_h
      base = @creative.effective_origin
      success = true

      if @creative.origin_id.present? && permitted.key?("parent_id")
        parent_id = permitted.delete("parent_id")
        success &&= @creative.update(parent_id: parent_id)
      end

      success &&= base.update(permitted)

      if success
        format.html { redirect_to @creative }
        format.json { head :ok }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: { errors: @creative.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    parent = @creative.parent
    unless @creative.has_permission?(Current.user, :admin)
      redirect_to @creative, alert: t("creatives.errors.no_permission") and return
    end
    if params[:delete_with_children]
      # Recursively destroy deletable descendants before deleting parent
      destroy_descendants_recursively(@creative, Current.user)
    else
      # Re-link children to parent
      @creative.children.each { |child| child.update(parent: parent) }
    end
    CreativeShare.where(creative: @creative).destroy_all
    @creative.destroy
  end

  def request_permission
    creative = @creative.effective_origin
    if creative.user == Current.user || creative.has_permission?(Current.user, :read)
      return head :unprocessable_entity
    end

    short_title = creative.effective_origin.description.to_plain_text.truncate(10)

    InboxItem.create!(
      owner: creative.user,
      message_key: "inbox.permission_requested",
      message_params: { user: Current.user.display_name, short_title: short_title },
      link: Rails.application.routes.url_helpers.creative_url(
        creative,
        Rails.application.config.action_mailer.default_url_options.merge(share_request: Current.user.email)
      )
    )

    head :ok
  end

  def recalculate_progress
    Creative.recalculate_all_progress!
    redirect_to creatives_path, notice: t("creatives.notices.progress_recalculated")
  end

  def reorder
    dragged = Creative.find_by(id: params[:dragged_id])
    target = Creative.find_by(id: params[:target_id])
    direction = params[:direction]
    return head :unprocessable_entity unless dragged && target && %w[up down child].include?(direction)

    if direction == "child"
      # Make dragged a child of target, append to end of children
      dragged.parent = target
      dragged.save!
      siblings = target.children.order(:sequence).to_a
      siblings.delete(dragged)
      siblings << dragged
      siblings.each_with_index do |creative, idx|
        creative.update_column(:sequence, idx)
      end
      head :ok
      return
    end

    # Up/down logic
    # Change parent if needed
    if dragged.parent != target.parent
      dragged.parent = target.parent
      dragged.save!
    end

    siblings = dragged.parent ? dragged.parent.children.order(:sequence).to_a : Creative.roots.order(:sequence).to_a
    siblings.delete(dragged)
    target_index = siblings.index(target)
    new_index = direction == "up" ? target_index : target_index + 1
    siblings.insert(new_index, dragged)

    # Reassign sequence values
    siblings.each_with_index do |creative, idx|
      creative.update_column(:sequence, idx)
    end

    head :ok
  end

  def import_markdown
    unless authenticated?
      render json: { error: "Unauthorized" }, status: :unauthorized and return
    end
    if params[:markdown].blank?
      render json: { error: "Invalid file type" }, status: :unprocessable_entity and return
    end
    parent = params[:parent_id].present? ? Creative.find_by(id: params[:parent_id]) : nil
    file = params[:markdown]
    created =
      case file.content_type
      when "text/markdown", "text/x-markdown", "application/octet-stream"
        content = file.read.force_encoding("UTF-8")
        MarkdownImporter.import(content, parent: parent, user: Current.user, create_root: true)
      when "application/vnd.ms-powerpoint",
           "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        PptImporter.import(file.tempfile, parent: parent, user: Current.user,
                           create_root: true, filename: file.original_filename)
      else
        render json: { error: "Invalid file type" }, status: :unprocessable_entity and return
      end
    if created.any?
      render json: { success: true, created: created.map(&:id) }
    else
      render json: { error: "No creatives created" }, status: :unprocessable_entity
    end
  end

  def append_as_parent
    @parent_creative = Creative.find_by(id: params[:parent_id]).parent
    redirect_to new_creative_path(parent_id: @parent_creative&.id, child_id: params[:parent_id], tags: params[:tags])
  end

  def append_below
    target = Creative.find_by(id: params[:creative_id])
    redirect_to new_creative_path(parent_id: target&.parent_id, after_id: target&.id, tags: params[:tags])
  end

  def set_plan
    plan_id = params[:plan_id]
    creative_ids = params[:creative_ids].to_s.split(",").map(&:strip).reject(&:blank?)
    plan = Plan.find_by(id: plan_id)
    if plan && creative_ids.any?
      Creative.where(id: creative_ids).find_each do |creative|
        creative.tags.find_or_create_by(label: plan, creative_id: creative.id)
      end
      flash[:notice] = t("creatives.index.plan_tags_applied", default: "Plan tags applied to selected creatives.")
    else
      flash[:alert] = t("creatives.index.plan_tag_failed", default: "Please select a plan and at least one creative.")
    end
    redirect_back fallback_location: creatives_path(select_mode: 1)
  end

  def remove_plan
    plan_id = params[:plan_id]
    creative_ids = params[:creative_ids].to_s.split(",").map(&:strip).reject(&:blank?)
    plan = Plan.find_by(id: plan_id)
    if plan && creative_ids.any?
      Creative.where(id: creative_ids).find_each do |creative|
        tag = creative.tags.find_by(label: plan, creative_id: creative.id)
        tag&.destroy
      end
      flash[:notice] = t("creatives.index.plan_tags_removed", default: "Plan tag removed from selected creatives.")
    else
      flash[:alert] = t("creatives.index.plan_tag_remove_failed", default: "Please select a plan and at least one creative.")
    end
    redirect_back fallback_location: creatives_path(select_mode: 1)
  end

  def children
    parent = Creative.find(params[:id])
    @expanded_state_map = CreativeExpandedState
                              .where(user_id: Current.user.id, creative_id: parent.id)
                              .first&.expanded_status || {}
    children = parent.children_with_permission(Current.user)
    level = params[:level].to_i
    render html: helpers.render_creative_tree(
      children,
      level,
      select_mode: params[:select_mode] == "1",
      max_level: Current.user&.display_level || User::DEFAULT_DISPLAY_LEVEL
    ).html_safe
  end

  def export_markdown
    creatives = if params[:parent_id]
      Creative.where(id: params[:parent_id])&.map(&:effective_origin) || []
    else
      Creative.where(parent_id: nil)
    end
    markdown = helpers.render_creative_tree_markdown(creatives)
    send_data markdown, filename: "creatives.md", type: "text/markdown"
  end

  private

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:description, :progress, :parent_id, :sequence, :origin_id)
    end

    def build_slide_ids(node)
      @slide_ids << node.id
      children = node.children.order(:sequence)
      if node.origin_id.present?
        linked_children = node.linked_children
        children = (children + linked_children).uniq.sort_by(&:sequence)
      end
      children.each { |child| build_slide_ids(child) }
    end

    # Recursively destroy all descendants the user can delete
    def destroy_descendants_recursively(creative, user)
      deletable_children = creative.children_with_permission(user, :admin)
      deletable_children.each do |child|
        destroy_descendants_recursively(child, user)
        CreativeShare.where(creative: child).destroy_all
        child.destroy
      end
    end
end
