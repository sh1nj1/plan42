# frozen_string_literal: true

module Collavre
  module Api
    module V1
      class AgentsController < BaseController
        # POST /api/v1/agent/register
        # Registers a Claude Code session as an agent:
        # 1. Finds or creates an AI User for this session
        # 2. Creates a Topic in the user's inbox
        # 3. Sets the AI user as primary agent on the topic
        def register
          agent_name = params[:name].to_s.strip
          if agent_name.blank?
            render json: { error: "name is required" }, status: :unprocessable_entity
            return
          end

          email = "#{agent_name}@agent.collavre.local"

          ai_user = User.find_or_initialize_by(email: email)
          if ai_user.new_record?
            ai_user.assign_attributes(
              name: "Claude #{agent_name}",
              password: SecureRandom.hex(32),
              llm_vendor: "anthropic",
              llm_model: "claude-code",
              created_by_id: current_user.id,
              searchable: false
            )
            ai_user.save!
          end

          inbox = Creative.inbox_for(current_user)
          topic_name = "Claude #{agent_name}"
          topic = inbox.topics.find_or_create_by!(name: topic_name) do |t|
            t.user = current_user
          end

          topic.set_primary_agent!(ai_user)

          render json: {
            agent_id: ai_user.id,
            agent_name: ai_user.name,
            topic_id: topic.id,
            topic_name: topic.name,
            inbox_creative_id: inbox.id,
            ws_url: "/cable"
          }, status: :ok
        end

        # DELETE /api/v1/agent/:id
        # Archives the agent's topic (session ended)
        def destroy
          ai_user = User.find_by(id: params[:id])
          unless ai_user&.ai_user? && ai_user.created_by_id == current_user.id
            render json: { error: "Agent not found" }, status: :not_found
            return
          end

          inbox = Creative.inbox_for(current_user)
          topic = inbox.topics.active.find_by(name: "Claude #{ai_user.email.split('@').first}")
          topic&.archive!

          head :no_content
        end

        # POST /api/v1/agent/reply
        # Creates a comment in a topic as the AI agent
        def reply
          topic = Topic.find_by(id: params[:topic_id])
          unless topic
            render json: { error: "Topic not found" }, status: :not_found
            return
          end

          creative = topic.creative&.effective_origin
          unless creative
            render json: { error: "Creative not found" }, status: :not_found
            return
          end

          agent = topic.primary_agent
          unless agent && agent.created_by_id == current_user.id
            render json: { error: "Not authorized" }, status: :forbidden
            return
          end

          comment = creative.comments.build(
            content: params[:text].to_s,
            topic: topic,
            user: agent,
            skip_default_user: true,
            skip_dispatch: true
          )

          if comment.save
            render json: { comment_id: comment.id }, status: :created
          else
            render json: { errors: comment.errors.full_messages }, status: :unprocessable_entity
          end
        end
      end
    end
  end
end
