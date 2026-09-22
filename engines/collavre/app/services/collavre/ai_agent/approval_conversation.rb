# frozen_string_literal: true

module Collavre
  module AiAgent
    # Persist provider-neutral messages, including tool IDs and Gemini thinking
    # signatures. Never re-run side effects from an interrupted tool batch.
    module ApprovalConversation
      def self.dump(messages)
        messages.map do |message|
          message.to_h.merge(
            content: dump_content(message.content),
            tool_calls: message.tool_calls&.transform_values(&:to_h)
          ).as_json
        end
      end

      def self.dump_content(content)
        return content unless content.is_a?(RubyLLM::Content)

        { text: content.text, attachments: content.attachments.map { |file| { data: file.encoded, filename: file.filename } } }
      end

      def self.restore(chat, pending)
        chat.reset_messages!
        pending.fetch("messages").each do |attributes|
          attrs = attributes.symbolize_keys
          if attrs[:content].is_a?(Hash)
            content = attrs[:content]
            attachments = content.fetch("attachments").map do |file|
              RubyLLM::Attachment.new(StringIO.new(Base64.strict_decode64(file.fetch("data"))), filename: file["filename"])
            end
            attrs[:content] = RubyLLM::Content.new(content["text"], attachments)
          end
          attrs[:tool_calls] = attrs[:tool_calls]&.transform_values do |call|
            RubyLLM::ToolCall.new(**call.symbolize_keys)
          end
          attrs[:thinking] = RubyLLM::Thinking.build(text: attrs[:thinking], signature: attrs.delete(:thinking_signature))
          chat.add_message(attrs)
        end
        append_results(chat, pending)
      end

      def self.append_results(chat, pending)
        answered = chat.messages.filter_map(&:tool_call_id)
        calls = chat.messages.flat_map { |message| message.tool_calls&.values || [] }
        calls.each do |call|
          next if answered.include?(call.id)

          result = if call.id == pending.fetch("tool_call_id")
            pending.fetch("decision")
          else
            { error: "Not executed because another call paused for human approval. Retry this call if still needed." }
          end
          chat.add_message(role: :tool, tool_call_id: call.id, content: result.to_json)
        end
      end
    end
  end
end
