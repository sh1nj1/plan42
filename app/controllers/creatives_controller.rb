class CreativesController < ApplicationController
  allow_unauthenticated_access only: %i[ index show ]
  before_action :set_creative, only: %i[ show edit update destroy ]

  def index
    @creatives = Creative.all
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

  private

    def set_creative
      @creative = Creative.find(params[:id])
    end

    def creative_params
      params.require(:creative).permit(:name, :description, :featured_image, :inventory_count, :parent_id)
    end
end
