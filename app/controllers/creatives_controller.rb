class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Plan42 app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  # allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy ]

  def index
    if params[:search].present?
      @creatives = Creative.joins(:rich_text_description)
                           .where("action_text_rich_texts.body LIKE ?", "%#{params[:search]}%")
                           .where(origin_id: nil)
                           .where(
                             "creatives.user_id = :user_id OR EXISTS (
                        SELECT 1 FROM creative_shares
                        WHERE creative_shares.creative_id = creatives.id
                          AND creative_shares.user_id = :user_id
                          AND creative_shares.permission >= :read
                      )",
                             user_id: Current.user.id,
                             read: CreativeShare.permissions[:read]
                           )
      @parent_creative = nil
    elsif params[:id]
      creative = Creative.where(id: params[:id])
                   .order(:sequence)
                          .select { |c| c.user == Current.user || c.has_permission?(Current.user, :read) }
                           .first
      @parent_creative = creative
      @creatives = creative.children_with_permission(Current.user, :read) if creative
    else
      @creatives = Creative.where(user: Current.user).where(parent_id: nil)
      @parent_creative = nil
    end
  end

  def show
    index
    render :index
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
  end

  def create
    @creative = Creative.new(creative_params)
    @creative.user = Current.user

    # Rebuild @child_creative from params if present
    if params[:child_id].present?
      @child_creative = Creative.find_by(id: params[:child_id])
      @child_creative.parent = @creative if @child_creative
    end

    if @creative.save
      @child_creative.save if @child_creative
      # Add CreativeShare for all users who have _tree permission to the parent
      if @creative.parent
        parent_shares = CreativeShare.where(creative: @creative.parent).where("permission = ? OR permission = ?", CreativeShare.permissions[:read_tree], CreativeShare.permissions[:write_tree])
        parent_shares.each do |parent_share|
          CreativeShare.create!(creative: @creative, user: parent_share.user, permission: parent_share.permission)
        end
      end
      redirect_to @creative
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @creative.update(creative_params)
      redirect_to @creative
    else
      render :edit, status: :unprocessable_entity
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
      @creative.children.update_all(parent_id: parent&.id)
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
      dragged.update!(parent_id: target.id)
      siblings = Creative.where(parent_id: target.id).order(:sequence).to_a
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
    if dragged.parent_id != target.parent_id
      dragged.update!(parent_id: target.parent_id)
    end

    siblings = Creative.where(parent_id: target.parent_id).order(:sequence).to_a
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
        desc = $2.strip
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
        desc = $3.strip
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
        desc = line.strip
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
    redirect_to new_creative_path(parent_id: @parent_creative&.id, child_id: params[:parent_id])
  end

  def set_plan
    plan_id = params[:plan_id]
    creative_ids = params[:creative_ids].to_s.split(',').map(&:strip).reject(&:blank?)
    plan = Plan.find_by(id: plan_id)
    if plan && creative_ids.any?
      Creative.where(id: creative_ids).find_each do |creative|
        # Assuming Tag model with fields: taggable (polymorphic), plan_id
        creative.tags.find_or_create_by(taggable: plan, creative_id: creative.id)
      end
      flash[:notice] = t('creatives.index.plan_tags_applied', default: 'Plan tags applied to selected creatives.')
    else
      flash[:alert] = t('creatives.index.plan_tag_failed', default: 'Please select a plan and at least one creative.')
    end
    redirect_to creatives_path(select_mode: 1)
  end

  def remove_plan
    plan_id = params[:plan_id]
    creative_ids = params[:creative_ids].to_s.split(',').map(&:strip).reject(&:blank?)
    plan = Plan.find_by(id: plan_id)
    if plan && creative_ids.any?
      Creative.where(id: creative_ids).find_each do |creative|
        tag = creative.tags.find_by(taggable: plan, creative_id: creative.id)
        tag&.destroy
      end
      flash[:notice] = t('creatives.index.plan_tags_removed', default: 'Plan tag removed from selected creatives.')
    else
      flash[:alert] = t('creatives.index.plan_tag_remove_failed', default: 'Please select a plan and at least one creative.')
    end
    redirect_to creatives_path(select_mode: 1)
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
