class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Collavre app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  allow_unauthenticated_access only: %i[ index children export_markdown show slide_view show_link ]
  before_action :set_creative, only: %i[ show edit update destroy request_permission parent_suggestions slide_view unconvert ]

  def show_link
    @creative_link = CreativeLink.find_by(id: params[:id])
    unless @creative_link
      redirect_to creatives_path, alert: t("creatives.errors.link_not_found", default: "Link not found")
      return
    end

    # Check permission on the origin
    unless @creative_link.origin.has_permission?(Current.user, :read)
      redirect_to creatives_path, alert: t("creatives.errors.no_permission")
      return
    end

    # Prevent Turbo from caching this page to avoid flash of stale content
    response.headers["Cache-Control"] = "no-store"

    # Set up params for index logic
    params[:id] = @creative_link.origin_id.to_s
    params[:link_parent_id] = @creative_link.parent_id.to_s

    # Use the same logic as index and render its template
    index
    render :index unless performed?
  end

  def unlink
    @creative_link = CreativeLink.find_by(id: params[:id])
    unless @creative_link
      head :not_found
      return
    end

    # Check permission - user must have admin permission on the parent
    unless @creative_link.parent.has_permission?(Current.user, :admin)
      head :forbidden
      return
    end

    @creative_link.destroy
    head :ok
  end

  def index
    # 권한 캐시: 요청 내 CreativeShare 모두 메모리에 올림
    # Current.creative_share_cache = CreativeShare.where(user: Current.user).index_by(&:creative_id)

    user_id_for_state = Current.user&.id
    if user_id_for_state.nil? && params[:id].present?
      # Public view: use owner's state
      target_creative = Creative.find_by(id: params[:id])
      user_id_for_state = target_creative&.effective_origin&.user_id
    end

    @expanded_state_map = if user_id_for_state
      CreativeExpandedState.where(user_id: user_id_for_state, creative_id: params[:id]).first&.expanded_status || {}
    else
      {}
    end
    index_result = Creatives::IndexQuery.new(user: Current.user, params: params.to_unsafe_h).call
    @creatives = index_result.creatives || []
    @parent_creative = index_result.parent_creative
    @shared_creative = index_result.shared_creative
    @shared_list = index_result.shared_list
    @overall_progress = index_result.overall_progress if params[:tags].present?
    @allowed_creative_ids = index_result.allowed_creative_ids
    @progress_map = index_result.progress_map

    # Set filtered_progress on parent creative if progress_map is available
    if @parent_creative && @progress_map && @progress_map.key?(@parent_creative.id.to_s)
      @parent_creative.filtered_progress = @progress_map[@parent_creative.id.to_s]
    end

    respond_to do |format|
      format.html
      format.json do
        if params[:simple].present?
          render json: serialize_creatives(@creatives)
        else
          @creatives_tree_json = build_tree(
            index_result.creatives,
            params: params,
            expanded_state_map: @expanded_state_map,
            level: 1,
            allowed_creative_ids: @allowed_creative_ids,
            progress_map: @progress_map,
            link_parent_id: params[:link_parent_id],
            parent_id: @parent_creative&.id
          )
          render json: { creatives: @creatives_tree_json }
        end
      end
    end
  end

  def show
    unless @creative.has_permission?(Current.user, :read)
      if Current.user
        redirect_to creatives_path, alert: t("creatives.errors.no_permission")
      else
        request_authentication
      end
      return
    end

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
        has_children = @creative.children.exists? || CreativeLink.exists?(parent_id: @creative.id)
        render json: {
          id: @creative.id,
          description: @creative.effective_description,
          description_raw_html: @creative.description,
          origin_id: @creative.origin_id,
          parent_id: @creative.parent_id,
          progress: @creative.progress,
          progress_html: view_context.render_creative_progress(@creative),
          depth: depth,
          prompt: @creative.prompt_for(Current.user),
          has_children: has_children
        }
      end
    end
  end

  def slide_view
    unless @creative.has_permission?(Current.user, :read)
      if Current.user
        redirect_to creatives_path, alert: t("creatives.errors.no_permission")
      else
        request_authentication
      end
      return
    end

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
      render partial: "inline_edit_form"
    end
  end

  def update
    respond_to do |format|
      permitted = creative_params.to_h
      base = @creative.effective_origin(Set.new)
      success = true

      # Handle parent_id change separately for Linked Creatives
      if @creative.origin_id.present? && permitted.key?("parent_id")
        parent_id = permitted.delete("parent_id")
        success &&= @creative.update(parent_id: parent_id)
      end

      # When updating the base (Origin), we must NOT pass origin_id.
      # Because if @creative is Linked, params might include origin_id.
      # Passing origin_id to the Origin creative causes it to fail validation (cannot changes if has origin)
      # or creates a self-cycle.
      permitted.delete("origin_id")
      permitted.delete(:origin_id)

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

    short_title = helpers.strip_tags(creative.effective_origin.description).truncate(10)

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



  def reorder
    dragged_ids = Array(params[:dragged_ids]).map(&:presence).compact
    target_id = params[:target_id]
    direction = params[:direction]

    if dragged_ids.any?
      reorderer.reorder_multiple(
        dragged_ids: dragged_ids,
        target_id: target_id,
        direction: direction
      )
    else
      reorderer.reorder(
        dragged_id: params[:dragged_id],
        target_id: target_id,
        direction: direction
      )
    end
    head :ok
  rescue Creatives::Reorderer::Error
    head :unprocessable_entity
  end

  def link_drop
    result = reorderer.link_drop(
      dragged_id: params[:dragged_id],
      target_id: params[:target_id],
      direction: params[:direction]
    )

    # Build tree node for the linked origin
    origin = result.origin
    level = result.parent.ancestors.count + 2  # Parent's level + 1
    nodes = build_tree(
      [ origin ],
      params: params,
      expanded_state_map: {},
      level: level
    )

    # Update the link_url to use /l/:link_id
    if nodes.first
      nodes.first[:link_url] = creative_link_view_path(result.creative_link.id)
    end

    render json: {
      nodes: nodes,
      link_id: result.creative_link.id,
      origin_id: origin.id,
      parent_id: result.parent&.id,
      direction: result.direction
    }
  rescue Creatives::Reorderer::Error
    head :unprocessable_entity
  end

  def append_as_parent
    @parent_creative = Creative.find_by(id: params[:parent_id]).parent
    redirect_to new_creative_path(parent_id: @parent_creative&.id, child_id: params[:parent_id], tags: params[:tags])
  end

  def append_below
    target = Creative.find_by(id: params[:creative_id])
    redirect_to new_creative_path(parent_id: target&.parent_id, after_id: target&.id, tags: params[:tags])
  end

  def children
    parent = Creative.find(params[:id])
    user_id = Current.user&.id || parent.effective_origin.user_id
    expanded_state_map = CreativeExpandedState
                            .where(user_id: user_id, creative_id: parent.id)
                            .first&.expanded_status || {}

    # Get actual children
    actual_children = parent.children_with_permission(Current.user)

    # Get linked origins via CreativeLink
    linked_origins = Creative.joins(:parent_links)
      .where(creative_links: { parent_id: parent.id })
      .select { |c| c.has_permission?(Current.user, :read) }

    children = (actual_children + linked_origins).uniq

    allowed_ids = nil
    progress_map = nil
    if params[:tags].present? || params[:min_progress].present? || params[:max_progress].present?
      result = Creatives::IndexQuery.new(user: Current.user, params: params.merge(id: params[:id])).call
      allowed_ids = result.allowed_creative_ids
      progress_map = result.progress_map
    end

    level = params[:level].to_i
    json_level = level.zero? ? 1 : level
    render json: {
      creatives: build_tree(
        children,
        params: params,
        expanded_state_map: expanded_state_map,
        level: json_level,
        select_mode: params[:select_mode] == "1",
        allowed_creative_ids: allowed_ids,
        progress_map: progress_map,
        link_parent_id: params[:link_parent_id],
        parent_id: parent.id
      )
    }
  end

  def unconvert
    base_creative = @creative.effective_origin
    parent = base_creative.parent
    if parent.nil?
      render json: { error: t("creatives.index.unconvert_no_parent") }, status: :unprocessable_entity and return
    end

    unless parent.has_permission?(Current.user, :feedback)
      render json: { error: t("creatives.errors.no_permission") }, status: :forbidden and return
    end

    unless base_creative.has_permission?(Current.user, :admin)
      render json: { error: t("creatives.errors.no_permission") }, status: :forbidden and return
    end

    markdown = helpers.render_creative_tree_markdown([ base_creative ])
    comment = nil

    ActiveRecord::Base.transaction do
      comment = parent.effective_origin.comments.create!(content: markdown, user: Current.user)
      base_creative.descendants.each(&:destroy!)
      base_creative.destroy!
    end

    render json: { comment_id: comment.id }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def export_markdown
    creatives = if params[:parent_id]
      parent_creative = Creative.find(params[:parent_id])
      effective_origin = parent_creative.effective_origin
      unless parent_creative.has_permission?(Current.user, :read) &&
             effective_origin.has_permission?(Current.user, :read)
        render plain: t("creatives.errors.no_permission"), status: :forbidden and return
      end
      [ effective_origin ]
    else
      Creative.where(parent_id: nil).map(&:effective_origin).uniq.select do |creative|
        creative.has_permission?(Current.user, :read)
      end
    end

    if creatives.empty?
      render plain: t("creatives.errors.no_permission"), status: :forbidden and return
    end

    markdown = helpers.render_creative_tree_markdown(creatives)
    send_data markdown, filename: "creatives.md", type: "text/markdown"
  end

  private
    def build_tree(collection, params:, expanded_state_map:, level:, select_mode: false, allowed_creative_ids: nil, progress_map: nil, link_parent_id: nil, parent_id: nil)
      Creatives::TreeBuilder.new(
        user: Current.user,
        params: params,
        view_context: view_context,
        expanded_state_map: expanded_state_map,
        select_mode: select_mode,
        max_level: Current.user&.display_level || User::DEFAULT_DISPLAY_LEVEL,
        allowed_creative_ids: allowed_creative_ids,
        progress_map: progress_map,
        link_parent_id: link_parent_id,
        parent_id: parent_id
      ).build(collection, level: level)
    end

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:description, :progress, :parent_id, :sequence, :origin_id)
    end

    def build_slide_ids(node)
      return unless node.has_permission?(Current.user, :read)

      @slide_ids << node.id
      children = node.children.order(:sequence)
      if node.origin_id.present?
        linked_children = node.linked_children
        children = (children + linked_children).uniq.sort_by(&:sequence)
      end
      children.each { |child| build_slide_ids(child) }
    end

    def serialize_creatives(collection)
      if params[:simple].present?
        collection.map { |c| { id: c.id, description: c.effective_description(nil, false), progress: c.progress } }
      else
        collection.map { |c| { id: c.id, description: c.effective_description, progress: c.progress } }
      end
    end

    def reorderer
      @reorderer ||= Creatives::Reorderer.new(user: Current.user)
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
