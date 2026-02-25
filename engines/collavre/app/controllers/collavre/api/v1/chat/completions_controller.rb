# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Chat
        class CompletionsController < BaseController
          def create
            messages = params[:messages] || []
            stream = params[:stream] == true || params[:stream] == "true"

            if messages.empty?
              render json: { error: { message: "messages is required", type: "invalid_request_error" } },
                     status: :bad_request
              return
            end

            agent = resolve_agent
            unless agent
              render json: { error: { message: "Invalid model", type: "invalid_request_error" } },
                     status: :bad_request
              return
            end

            system_prompt = build_system_prompt(messages, agent)
            contents = build_contents(messages)

            client = Collavre::AiClient.new(
              vendor: agent.llm_vendor,
              model: agent.llm_model,
              system_prompt: system_prompt,
              llm_api_key: Current.user.llm_api_key,
              context: { creative: collavre_creative, user: Current.user }
            )

            model_name = params[:model] || "collavre/#{agent.id}"

            if stream
              stream_response(client, contents, model_name)
            else
              non_stream_response(client, contents, model_name)
            end
          end

          private

          def resolve_agent
            model_param = params[:model].to_s

            # Format: "collavre/{ai_id}"
            if model_param.start_with?("collavre/")
              ai_id = model_param.sub("collavre/", "")
              agent = Collavre::User.find_by(id: ai_id)
              return nil unless agent&.ai_user?
              return nil unless agent_accessible?(agent)

              agent
            else
              # No model specified or raw model name — use first available agent
              # or create a virtual agent-like object with defaults
              VirtualAgent.new(
                llm_vendor: "google",
                llm_model: model_param.presence || "gemini-2.5-flash",
                system_prompt: nil
              )
            end
          end

          def agent_accessible?(agent)
            agent.created_by_id == Current.user.id || agent.searchable?
          end

          def build_system_prompt(messages, agent)
            parts = []

            # Agent's own system prompt
            parts << agent.system_prompt if agent.system_prompt.present?

            # Extract system messages from request
            system_messages = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
            system_messages.each do |msg|
              parts << (msg[:content] || msg["content"])
            end

            # Inject Collavre context if creative is specified
            parts << build_creative_context if collavre_creative

            parts.compact.join("\n\n").presence || Collavre::AiClient::SYSTEM_INSTRUCTIONS
          end

          def build_creative_context
            context_parts = []
            context_parts << "## Collavre Context"
            context_parts << "Creative: #{collavre_creative.title}" if collavre_creative.title.present?

            if collavre_topic
              context_parts << "Topic: #{collavre_topic.title}" if collavre_topic.title.present?
            end

            if collavre_creative
              scope = collavre_creative.comments
                                       .where(private: false)
                                       .order(created_at: :desc)
                                       .limit(20)
              scope = scope.where(topic_id: collavre_topic.id) if collavre_topic

              recent_comments = scope.includes(:user).to_a.reverse
              if recent_comments.any?
                context_parts << "\n### Recent Discussion"
                recent_comments.each do |comment|
                  author = comment.user&.name || "Unknown"
                  context_parts << "- **#{author}**: #{comment.content.to_s.truncate(500)}"
                end
              end
            end

            context_parts.join("\n")
          end

          def build_contents(messages)
            messages.reject { |m|
              role = m[:role] || m["role"]
              role == "system"
            }.map { |m|
              role = m[:role] || m["role"]
              content = m[:content] || m["content"]
              { role: role, text: content }
            }
          end

          def non_stream_response(client, contents, model)
            result = client.chat(contents)
            completion_id = "chatcmpl-#{SecureRandom.hex(12)}"

            render json: {
              id: completion_id,
              object: "chat.completion",
              created: Time.current.to_i,
              model: model,
              choices: [
                {
                  index: 0,
                  message: { role: "assistant", content: result || "" },
                  finish_reason: "stop"
                }
              ],
              usage: {
                prompt_tokens: 0,
                completion_tokens: 0,
                total_tokens: 0
              }
            }
          end

          def stream_response(client, contents, model)
            completion_id = "chatcmpl-#{SecureRandom.hex(12)}"

            response.headers["Content-Type"] = "text/event-stream"
            response.headers["Cache-Control"] = "no-cache"
            response.headers["Connection"] = "keep-alive"

            self.response_body = Enumerator.new do |yielder|
              client.chat(contents) do |chunk|
                data = {
                  id: completion_id,
                  object: "chat.completion.chunk",
                  created: Time.current.to_i,
                  model: model,
                  choices: [
                    {
                      index: 0,
                      delta: { content: chunk },
                      finish_reason: nil
                    }
                  ]
                }
                yielder << "data: #{data.to_json}\n\n"
              end

              final = {
                id: completion_id,
                object: "chat.completion.chunk",
                created: Time.current.to_i,
                model: model,
                choices: [
                  {
                    index: 0,
                    delta: {},
                    finish_reason: "stop"
                  }
                ]
              }
              yielder << "data: #{final.to_json}\n\n"
              yielder << "data: [DONE]\n\n"
            end
          end

          # Simple struct for raw model name requests (without collavre/ prefix)
          VirtualAgent = Struct.new(:llm_vendor, :llm_model, :system_prompt, keyword_init: true) do
            def ai_user?
              true
            end
          end
        end
      end
    end
  end
end
