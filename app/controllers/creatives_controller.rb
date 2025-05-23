class CreativesController < ApplicationController

  # TODO: for not for security reasons for this Plan42 app, we don't expose to public, later it should be controlled by roles for each Creatives
  # Removed unauthenticated access to index and show actions
  # allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy ]

  def index
    @creatives = Creative.order(:sequence)
  end

  def show
  end

  def new
    @creative = Creative.new
  end

  def create
    @creative = Creative.new(creative_params)
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
    redirect_to creatives_path, notice: 'All parent progress recalculated.'
  end

  private

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:description, :featured_image, :progress, :parent_id, :sequence)
    end
end
