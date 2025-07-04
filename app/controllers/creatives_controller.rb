class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Collavre app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  # allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy ]

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
      @creatives = Creative.joins(:rich_text_description)
                           .left_joins(:comments) # Include comments to allow searching in them
                           .where("action_text_rich_texts.body LIKE :q OR comments.content LIKE :q", q: "%#{params[:search]}%")
                           .where(origin_id: nil)
                           .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
      @parent_creative = nil
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
  end

  def show
    index
    respond_to do |format|
      format.html { render :index }
      format.json do
        render json: {
          id: @creative.id,
          description: @creative.effective_description,
          parent_id: @creative.parent_id,
          progress: @creative.progress
        }
      end
    end
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

    respond_to do |format|
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
        # Propagate all shares from the parent to the new child
        if @creative.parent
          CreativeShare.where(creative: @creative.parent).find_each do |parent_share|
            CreativeShare.create!(creative: @creative, user: parent_share.user, permission: parent_share.permission)
          end
        end
        if params[:tags].present?
          Array(params[:tags]).each do |tag_id|
            @creative.tags.create(label_id: tag_id)
          end
        end
        format.html { redirect_to @creative }
        format.json { render json: { id: @creative.id } }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: { errors: @creative.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def edit
    if params[:inline]
      render partial: "form", locals: { creative: @creative }
    end
  end

  def update
    respond_to do |format|
      if @creative.effective_origin.update(creative_params)
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
    unless @creative.has_permission?(Current.user, :write)
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
    if parent
      redirect_to creative_path(parent)
    else
      redirect_to creatives_path
    end
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
    if params[:markdown].blank? || !params[:markdown].content_type.in?(%w[text/markdown text/x-markdown application/octet-stream])
      render json: { error: "Invalid file type" }, status: :unprocessable_entity and return
    end
    parent = params[:parent_id].present? ? Creative.find_by(id: params[:parent_id]) : nil
    file = params[:markdown]
    content = file.read.force_encoding("UTF-8")
    lines = content.lines
    image_refs = {}
    lines.reject! do |ln|
      if ln =~ /^\s*\[([^\]]+)\]:\s*<\s*(data:image\/[^>]+)\s*>\s*$/
        image_refs[$1] = $2.strip
        true
      else
        false
      end
    end
    created = []

    # Find page title (first non-empty, non-heading, non-list line)
    i = 0
    while i < lines.size && lines[i].strip.empty?
      i += 1
    end
    root_creative = nil
    if i < lines.size && lines[i] !~ /^\s*#/ && lines[i] !~ /^\s*[-*+]/
      page_title = lines[i].strip
      root_creative = Creative.create(user: Current.user, parent: parent, description: page_title)
      created << root_creative
      i += 1
    end
    # If no page title, use parent as root
    root_creative ||= parent

    # Now, stack always starts with root_creative
    stack = [ [ 0, root_creative ] ]
    while i < lines.size
      line = lines[i]
      if line =~ /^(#+)\s+(.*)$/ # Heading
        level = $1.length # 1 for h1, 2 for h2, etc.
        desc = helpers.markdown_links_to_html($2.strip, image_refs)
        while stack.any? && stack.last[0] >= level
          stack.pop
        end
        new_parent = stack.any? ? stack.last[1] : root_creative
        c = Creative.create(user: Current.user, parent: new_parent, description: desc)
        created << c
        stack << [ level, c ]
        i += 1
      elsif line =~ /^([ \t]*)([-*+])\s+(.*)$/ # Bullet list
        indent = $1.length
        desc = helpers.markdown_links_to_html($3.strip, image_refs)
        bullet_level = 10 + indent / 2
        while stack.any? && stack.last[0] >= bullet_level
          stack.pop
        end
        new_parent = stack.any? ? stack.last[1] : root_creative
        c = Creative.create(user: Current.user, parent: new_parent, description: desc)
        created << c
        stack << [ bullet_level, c ]
        i += 1
      elsif !line.strip.empty? # Paragraph/content under a heading
        desc = helpers.markdown_links_to_html(line.strip, image_refs)
        new_parent = stack.any? ? stack.last[1] : root_creative
        c = Creative.create(user: Current.user, parent: new_parent, description: desc)
        created << c
        i += 1
      else
        i += 1
      end
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
      params.require(:creative).permit(:description, :progress, :parent_id, :sequence)
    end

    # Recursively destroy all descendants the user can delete
    def destroy_descendants_recursively(creative, user)
      deletable_children = creative.children_with_permission(user, :write)
      deletable_children.each do |child|
        destroy_descendants_recursively(child, user)
        CreativeShare.where(creative: child).destroy_all
        child.destroy
      end
    end
end
