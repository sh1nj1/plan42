class CreativesController < ApplicationController
  # TODO: for not for security reasons for this Plan42 app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  # allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy ]

  def index
    @creatives = Creative.where(user: Current.user).order(:sequence)
    if params[:id].present?
      @parent_creative = Creative.find_by(id: params[:id])
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
  end

  def create
    @creative = Creative.new(creative_params)
    @creative.user = Current.user
    if @creative.save
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
    @creative.destroy
    redirect_to creatives_path
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

  private

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:description, :progress, :parent_id, :sequence)
    end
end
