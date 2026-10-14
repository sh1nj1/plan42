# frozen_string_literal: true

module Collavre
  class AiClient
    module Decision
      # Returns {answers: {name: {choice/probability/score: value}}, reason:, source:}
      # with string keys. Errors propagate so callers cannot mistake a failure for DONE.
      def judge(input, questions:)
        definitions = DecisionQuestions.new(questions)
        if self.class.supports?(vendor, :judge)
          native_decision(input, definitions)
        else
          chat_decision(input, definitions)
        end
      rescue RubyLLM::Error => e
        raise unless self.class.supports?(vendor, :chat) && [ 404, 405, 501 ].include?(e.response&.status)

        chat_decision(input, definitions)
      end

      private

      def native_decision(input, definitions)
        @conversation = nil
        start_usage_tracking
        response = build_llm_context.judge(
          { instructions: system_prompt, input: input }, questions: definitions.definitions,
          model: model, provider: VENDOR_TO_PROVIDER.fetch(vendor), assume_model_exists: true
        )
        payload = { "answers" => response.answers.transform_values(&:to_h) }
        definitions.normalize(payload, source: "judge")
      rescue StandardError => e
        error_message = e.message
        raise
      ensure
        finalize_chat_usage(response, [ { role: "user", text: input.to_json } ], payload&.to_json,
          error_message, response&.tokens&.input, response&.tokens&.output)
      end

      def chat_decision(input, definitions)
        return adapter_decision(input, definitions) unless VENDOR_TO_PROVIDER.key?(vendor)

        perform_chat_decision(input, definitions, structured: true)
      rescue RubyLLM::BadRequestError => e
        raise unless e.message.match?(/schema|response_format|structured.output/i)

        perform_chat_decision(input, definitions, structured: false)
      end

      def perform_chat_decision(input, definitions, structured:)
        raise ArgumentError, "Vendor cannot answer chat decisions" unless self.class.supports?(vendor, :chat)

        start_usage_tracking
        @conversation = build_conversation
        install_usage_tracking(@conversation)
        @conversation.with_schema(definitions.schema) if structured
        prompt = decision_prompt(input, definitions)
        response = @conversation.ask(prompt)
        payload = parse_decision_content(response.content)
        definitions.normalize(payload, source: "chat")
      rescue StandardError => e
        error_message = e.message
        raise
      ensure
        finalize_chat_usage(response, [ { role: "user", text: prompt } ], payload&.to_json,
          error_message, response&.tokens&.input, response&.tokens&.output)
      end

      def adapter_decision(input, definitions)
        prompt = decision_prompt(input, definitions)
        streamed = +""
        response = chat([ { role: "user", text: prompt } ]) { |delta| streamed << delta }
        definitions.normalize(parse_decision_content(response.presence || streamed), source: "chat")
      end

      def decision_prompt(input, definitions)
        { input: input, questions: definitions.definitions, response_schema: definitions.schema,
          instruction: "Return only JSON matching response_schema. Explain missing actions in reason." }.to_json
      end

      def parse_decision_content(content)
        return content if content.is_a?(Hash)

        JSON.parse(content.to_s.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, ""))
      end
    end
  end
end
