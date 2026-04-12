# frozen_string_literal: true

module CollavreCompletionApi
  module Api
    module V1
      module Chat
        class CompletionsController < BaseController
          CREATIVE_CONTEXT_COMMENT_LIMIT = 20

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

            # Use agent owner's llm_api_key for external LLM calls
            api_key = agent.respond_to?(:llm_api_key) ? agent.llm_api_key : nil
            api_key ||= agent.respond_to?(:creator) ? agent.creator&.llm_api_key : nil

            client = Collavre::AiClient.new(
              vendor: agent.llm_vendor,
              model: agent.llm_model,
              system_prompt: system_prompt,
              llm_api_key: api_key,
              gateway_url: agent.respond_to?(:gateway_url) ? agent.gateway_url : nil,
              context: { creative: collavre_creative, user: current_user, topic_id: collavre_topic&.id }
            )

            model_name = params[:model] || agent_model_id(agent)

            if stream
              stream_response(client, contents, model_name)
            else
              non_stream_response(client, contents, model_name)
            end
          end

          private

          def resolve_agent
            resolve_agent_by_model(params[:model].to_s)
          end

          def build_system_prompt(messages, agent)
            parts = []

            parts << agent.system_prompt if agent.system_prompt.present?

            system_messages = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
            system_messages.each do |msg|
              parts << (msg[:content] || msg["content"])
            end

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

            scope = collavre_creative.comments
                                     .where(private: false)
                                     .order(created_at: :desc)
            scope = scope.where(topic_id: collavre_topic.id) if collavre_topic
            recent_comments = scope.limit(CREATIVE_CONTEXT_COMMENT_LIMIT)
                                   .includes(:user).to_a.reverse

            if recent_comments.any?
              context_parts << "\n### Recent Discussion"
              recent_comments.each do |comment|
                author = comment.user&.name || "Unknown"
                context_parts << "- **#{author}**: #{comment.content.to_s.truncate(500)}"
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

            prompt_tokens = client.last_input_tokens
            completion_tokens = client.last_output_tokens

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
                prompt_tokens: prompt_tokens,
                completion_tokens: completion_tokens,
                total_tokens: prompt_tokens + completion_tokens
              }
            }
          end

          def stream_response(client, contents, model)
            completion_id = "chatcmpl-#{SecureRandom.hex(12)}"

            response.headers["Content-Type"] = "text/event-stream"
            response.headers["Cache-Control"] = "no-cache"
            response.headers["Connection"] = "keep-alive"

            self.response_body = Enumerator.new do |yielder|
              begin
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
              rescue StandardError => e
                error_data = {
                  id: completion_id,
                  object: "chat.completion.chunk",
                  created: Time.current.to_i,
                  model: model,
                  choices: [
                    {
                      index: 0,
                      delta: { content: "\n\n⚠️ Error: #{e.message}" },
                      finish_reason: "stop"
                    }
                  ]
                }
                yielder << "data: #{error_data.to_json}\n\n"
              ensure
                yielder << "data: [DONE]\n\n"
              end
            end
          end
        end
      end
    end
  end
end
