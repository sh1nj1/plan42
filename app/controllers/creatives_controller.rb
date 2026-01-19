class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Collavre app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  allow_unauthenticated_access only: %i[ index children export_markdown show slide_view ]
  before_action :set_creative, only: %i[ show edit update destroy request_permission parent_suggestions slide_view unconvert ]

  def index
    respond_to do |format|
      format.html do
        # HTML only needs parent_creative for nav/title - skip expensive filtered queries
        # Must check permission to avoid leaking metadata (og:title, etc.) to unauthorized users
        if params[:id].present?
          creative = Creative.find_by(id: params[:id])
          @parent_creative = creative if creative&.has_permission?(Current.user, :read)
        end
        @creatives = []  # CSR will fetch via JSON
        @shared_list = @parent_creative ? @parent_creative.all_shared_users : []
      end
      format.json do
        # Full query only for JSON requests
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
        @overall_progress = index_result.overall_progress if any_filter_active?
        @allowed_creative_ids = index_result.allowed_creative_ids
        @progress_map = index_result.progress_map

        # Set filtered_progress on parent creative if progress_map is available
        if @parent_creative && @progress_map && @progress_map.key?(@parent_creative.id.to_s)
          @parent_creative.filtered_progress = @progress_map[@parent_creative.id.to_s]
        end

        # Disable caching for filtered results to ensure fresh data
        expires_now if any_filter_active?

        if params[:simple].present?
          render json: serialize_creatives(@creatives)
        else
          @creatives_tree_json = build_tree(
            index_result.creatives,
            params: params,
            expanded_state_map: @expanded_state_map,
            level: 1,
            allowed_creative_ids: @allowed_creative_ids,
            progress_map: @progress_map
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
        # Use HTTP caching with ETag - must vary by user since response includes user-specific data
        # ETag must also include prompt comment and children timestamps since those are in response
        effective = @creative.effective_origin
        cache_user = Current.user&.id || "anon"

        # Include prompt comment timestamp (user-specific private comments starting with "> ")
        # Note: LIKE '> %' uses index prefix scan if available; consider dedicated prompt flag if bottleneck
        prompt_updated = if Current.user
          @creative.comments
            .where(private: true, user: Current.user)
            .where("content LIKE ?", "> %")
            .maximum(:updated_at)
        end

        # Get children stats in a single query, reuse for has_children
        # Use separate Arel.sql args so pick returns an array; unscope order to avoid Postgres aggregate error
        children_count, children_max_updated = @creative.children
          .unscope(:order)
          .pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(updated_at)"))
        children_count = children_count.to_i  # Handle nil and string type-casting from adapters
        children_key = "#{children_count}-#{children_max_updated&.to_i}"

        last_modified = [
          @creative.updated_at,
          effective.updated_at,
          prompt_updated
        ].compact.max

        etag = [
          "creative",
          @creative.cache_key_with_version,
          effective.cache_key_with_version,
          "user",
          cache_user,
          "prompt",
          prompt_updated&.to_i,
          "children",
          children_key
        ].join(":")

        if stale?(etag: etag, last_modified: last_modified, public: false)
          root = params[:root_id] ? Creative.find_by(id: params[:root_id]) : nil
          depth = if root
                    (@creative.ancestors.count - root.ancestors.count) + 1
          else
                    @creative.ancestors.count + 1
          end
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
            has_children: children_count > 0
          }
        end
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

    new_creative = result.new_creative
    level = new_creative.ancestors.count + 1
    nodes = build_tree(
      [ new_creative ],
      params: params,
      expanded_state_map: {},
      level: level
    )

    render json: {
      nodes: nodes,
      creative_id: new_creative.id,
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
    effective = parent.effective_origin
    # user_id for expanded_state lookup - use owner's state for anonymous users
    state_user_id = Current.user&.id || effective.user_id

    # HTTP caching disabled for children endpoint:
    # Response depends on child updates, permission changes (CreativeSharesCache),
    # and CreativeExpandedState. Tracking all dependencies reliably is expensive
    # (requires descendant_ids query). Stale 304 responses could leak data after
    # permission revocation. Re-enable when a cheap version key mechanism exists.
    # Use private + no-store to prevent any caching (proxy or browser).
    response.headers["Cache-Control"] = "private, no-store"

    has_filters = params[:tags].present? || params[:min_progress].present? || params[:max_progress].present?
    if has_filters
      result = Creatives::IndexQuery.new(user: Current.user, params: params.merge(id: params[:id])).call
      render_children_json(parent, state_user_id, result.allowed_creative_ids, result.progress_map)
    else
      render_children_json(parent, state_user_id, nil, nil)
    end
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
    def build_tree(collection, params:, expanded_state_map:, level:, select_mode: false, allowed_creative_ids: nil, progress_map: nil)
      Creatives::TreeBuilder.new(
        user: Current.user,
        params: params,
        view_context: view_context,
        expanded_state_map: expanded_state_map,
        select_mode: select_mode,
        max_level: Current.user&.display_level || User::DEFAULT_DISPLAY_LEVEL,
        allowed_creative_ids: allowed_creative_ids,
        progress_map: progress_map
      ).build(collection, level: level)
    end

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:description, :progress, :parent_id, :sequence, :origin_id)
    end

    def any_filter_active?
      params[:tags].present? ||
        params[:min_progress].present? ||
        params[:max_progress].present? ||
        params[:search].present? ||
        params[:comment] == "true" ||
        params[:has_comments].present? ||
        params[:due_before].present? ||
        params[:due_after].present? ||
        params[:has_due_date].present? ||
        params[:assignee_id].present? ||
        params[:unassigned].present?
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

    def render_children_json(parent, user_id, allowed_ids, progress_map)
      expanded_state_map = CreativeExpandedState
                              .where(user_id: user_id, creative_id: parent.id)
                              .first&.expanded_status || {}
      children = parent.children_with_permission(Current.user)

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
          progress_map: progress_map
        )
      }
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
