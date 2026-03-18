module Collavre
  class TopicsController < ApplicationController
    before_action :set_creative

    def index
      is_owner = @creative.user == Current.user
      can_manage = @creative.has_permission?(Current.user, :admin) || is_owner
      can_create_topic = can_manage || @creative.has_permission?(Current.user, :write)

      active_topics = @creative.topics.active.order(:created_at).to_a
      preload_primary_agents(active_topics)
      archived_topics = @creative.topics.archived.order(:created_at)

      render json: {
        topics: active_topics.map { |t| topic_json(t) },
        archived_topics: archived_topics,
        can_manage: can_manage,
        can_create_topic: can_create_topic
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

    def archive
      unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic = @creative.topics.find(params[:id])
      topic.archive!

      TopicsChannel.broadcast_to(
        @creative,
        { action: "archived", topic: topic.slice(:id, :name) }
      )
      render json: { success: true }
    end

    def unarchive
      unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic = @creative.topics.find(params[:id])
      topic.unarchive!

      TopicsChannel.broadcast_to(
        @creative,
        { action: "unarchived", topic: topic.slice(:id, :name, :archived_at) }
      )
      render json: { success: true }
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

    def set_primary_agent
      unless @creative.has_permission?(Current.user, :write) || @creative.user == Current.user
        render json: { error: I18n.t("collavre.topics.no_permission") }, status: :forbidden and return
      end

      topic = @creative.topics.find(params[:id])
      agent = User.find(params[:agent_id])

      unless agent.ai_user?
        render json: { error: I18n.t("collavre.topics.not_ai_agent") }, status: :unprocessable_entity and return
      end

      policy = OrchestratorPolicy.find_or_initialize_by(
        policy_type: "arbitration",
        scope_type: "Topic",
        scope_id: topic.id
      )
      policy.update!(
        config: {
          "strategy" => "primary_first",
          "primary_agent_id" => agent.id
        },
        priority: 10,
        enabled: true
      )

      TopicsChannel.broadcast_to(
        @creative,
        {
          action: "updated",
          topic: topic_json_with_agent(topic, agent)
        }
      )

      render json: { success: true, topic: topic_json_with_agent(topic, agent) }
    end

    private

    def set_creative
      @creative = Creative.find(params[:creative_id]).effective_origin
    end

    def topic_params
      params.require(:topic).permit(:name)
    end

    # Batch-load primary agents for all topics to avoid N+1 queries
    def preload_primary_agents(topics)
      topic_ids = topics.map(&:id)
      return if topic_ids.empty?

      policies = OrchestratorPolicy.where(
        policy_type: "arbitration",
        scope_type: "Topic",
        scope_id: topic_ids
      ).index_by { |p| p.scope_id.to_i }

      agent_ids = policies.values.filter_map { |p| p.config&.dig("primary_agent_id") }
      agents = agent_ids.present? ? User.where(id: agent_ids).includes(avatar_attachment: :blob).index_by(&:id) : {}

      topics.each do |topic|
        policy = policies[topic.id]
        agent_id = policy&.config&.dig("primary_agent_id")
        topic.instance_variable_set(:@_primary_agent, agents&.dig(agent_id))
      end
    end

    def topic_json(topic)
      data = topic.slice(:id, :name)
      agent = topic.instance_variable_get(:@_primary_agent) || topic.primary_agent
      if agent
        data[:primary_agent] = agent_json(agent)
      end
      data
    end

    def topic_json_with_agent(topic, agent)
      data = topic.slice(:id, :name)
      data[:primary_agent] = agent_json(agent)
      data
    end

    def agent_json(agent)
      {
        id: agent.id,
        name: agent.display_name,
        avatar_url: view_context.user_avatar_url(agent, size: 20)
      }
    end
  end
end
