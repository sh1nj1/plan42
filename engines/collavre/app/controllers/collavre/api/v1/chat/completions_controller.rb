# frozen_string_literal: true

module Collavre
  module Api
    module V1
      module Chat
        class CompletionsController < BaseController
          def create
            model = params[:model] || "gemini-2.5-flash"
            messages = params[:messages] || []
            stream = params[:stream] == true || params[:stream] == "true"

            if messages.empty?
              render json: { error: { message: "messages is required", type: "invalid_request_error" } },
                     status: :bad_request
              return
            end

            system_prompt = build_system_prompt(messages)
            contents = build_contents(messages)

            client = Collavre::AiClient.new(
              vendor: "google",
              model: model,
              system_prompt: system_prompt,
              llm_api_key: Current.user.llm_api_key,
              context: { creative: collavre_creative, user: Current.user }
            )

            if stream
              stream_response(client, contents, model)
            else
              non_stream_response(client, contents, model)
            end
          end

          private

          def build_system_prompt(messages)
            parts = []

            # Extract system messages
            system_messages = messages.select { |m| m[:role] == "system" || m["role"] == "system" }
            system_messages.each do |msg|
              parts << (msg[:content] || msg["content"])
            end

            # Inject Collavre context if creative is specified
            if collavre_creative
              parts << build_creative_context
            end

            parts.compact.join("\n\n").presence || Collavre::AiClient::SYSTEM_INSTRUCTIONS
          end

          def build_creative_context
            context_parts = []
            context_parts << "## Collavre Context"
            context_parts << "Creative: #{collavre_creative.title}" if collavre_creative.title.present?

            if collavre_topic
              context_parts << "Topic: #{collavre_topic.title}" if collavre_topic.title.present?
            end

            # Add recent comments as context
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

              # Send final chunk
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
        end
      end
    end
  end
end
