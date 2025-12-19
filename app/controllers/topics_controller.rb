class TopicsController < ApplicationController
  before_action :set_creative

  def index
    can_manage = @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
    render json: {
      topics: @creative.topics.order(:created_at),
      can_manage: can_manage
    }
  end

  def create
    unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
      render json: { error: I18n.t("topics.no_permission") }, status: :forbidden and return
    end

    topic = @creative.topics.build(topic_params)
    topic.user = Current.user

    if topic.save
      TopicsChannel.broadcast_to(
        @creative,
        { action: "created", topic: topic.slice(:id, :name) }
      )
      render json: topic, status: :created
    else
      render json: { errors: topic.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    unless @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
      render json: { error: I18n.t("topics.no_permission") }, status: :forbidden and return
    end

    topic = @creative.topics.find(params[:id])
    topic_id = topic.id
    topic.destroy

    TopicsChannel.broadcast_to(
      @creative,
      { action: "deleted", topic_id: topic_id }
    )
    head :no_content
  end

  private

  def set_creative
    @creative = Creative.find(params[:creative_id]).effective_origin
  end

  def topic_params
    params.require(:topic).permit(:name)
  end
end
