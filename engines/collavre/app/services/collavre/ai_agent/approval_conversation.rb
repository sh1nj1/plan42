# frozen_string_literal: true

module Collavre
  module AiAgent
    # Persist provider-neutral messages, including tool IDs and Gemini thinking
    # signatures. Never re-run side effects from an interrupted tool batch.
    module ApprovalConversation
      def self.restoring_snapshot?(pending)
        return false unless pending

        pending["kind"] == "approval_gate" ||
          (pending["approved"] && pending.key?("result") && pending["messages"].present?)
      end

      def self.dump(messages)
        messages.map do |message|
          message.to_h.merge(
            attachments: message.attachments.map { |file| { data: file.encoded, filename: file.filename } },
            tool_calls: message.tool_calls&.transform_values(&:to_h)
          ).as_json
        end
      end

      def self.restore(chat, pending)
        chat.messages = []
        pending.fetch("messages").each do |attributes|
          attrs = attributes.symbolize_keys
          restore_attachments!(attrs)
          attrs[:tool_calls] = attrs[:tool_calls]&.transform_values do |call|
            RubyLLM::ToolCall.new(**call.symbolize_keys)
          end
          attrs[:thinking] = RubyLLM::Thinking.build(text: attrs[:thinking], signature: attrs.delete(:thinking_signature))
          chat.add_message(attrs)
        end
        append_results(chat, pending)
      end

      def self.restore_attachments!(attrs)
        attrs[:attachments] = Array(attrs[:attachments]).map do |file|
          RubyLLM::Attachment.new(StringIO.new(Base64.strict_decode64(file.fetch("data"))), filename: file["filename"])
        end
      end

      def self.append_results(chat, pending)
        answered = chat.messages.filter_map(&:tool_call_id)
        calls = chat.messages.flat_map { |message| message.tool_calls&.values || [] }
        calls.each do |call|
          next if answered.include?(call.id)

          result = if call.id == pending.fetch("tool_call_id")
            pending.key?("result") ? pending.fetch("result") : pending.fetch("decision")
          else
            { error: "Not executed because another call paused for human approval. Retry this call if still needed." }
          end
          chat.add_message(role: :tool, tool_call_id: call.id, content: result.to_json)
        end
      end
    end
  end
end
