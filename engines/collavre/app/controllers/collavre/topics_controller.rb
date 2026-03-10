module Collavre
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
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
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

    def update
      unless @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic = @creative.topics.find(params[:id])

      if topic.update(topic_params)
        TopicsChannel.broadcast_to(
          @creative,
          { action: "updated", topic: topic.slice(:id, :name) }
        )
        render json: topic
      else
        render json: { errors: topic.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      unless @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
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

    def move
      unless @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic = @creative.topics.find(params[:id])
      target_creative = Creative.find(params[:target_creative_id]).effective_origin

      unless target_creative.has_permission?(Current.user, :write) || target_creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.move.no_target_permission") }, status: :forbidden and return
      end

      # Check for duplicate topic name in target creative
      if target_creative.topics.where(name: topic.name).exists?
        render json: { error: I18n.t("collavre.topics.move.duplicate_name", name: topic.name) }, status: :unprocessable_entity and return
      end

      Topic.transaction do
        topic.comments.update_all(creative_id: target_creative.id)
        topic.update!(creative: target_creative)
      end

      TopicsChannel.broadcast_to(
        @creative,
        { action: "deleted", topic_id: topic.id }
      )
      TopicsChannel.broadcast_to(
        target_creative,
        { action: "created", topic: topic.slice(:id, :name) }
      )

      render json: { success: true, topic: topic.slice(:id, :name), target_creative_id: target_creative.id }
    end

    def reorder
      unless @creative.has_permission?(Current.user, :admin) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic_ids = params[:topic_ids]
      unless topic_ids.is_a?(Array) && topic_ids.present?
        render json: { error: "Invalid topic_ids" }, status: :unprocessable_entity and return
      end

      Topic.transaction do
        topic_ids.each_with_index do |id, index|
          @creative.topics.where(id: id).update_all(position: index)
        end
      end

      TopicsChannel.broadcast_to(
        @creative,
        { action: "reordered", topic_ids: topic_ids }
      )

      render json: { success: true }
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
    end

    def topic_params
      params.require(:topic).permit(:name)
    end
  end
end
