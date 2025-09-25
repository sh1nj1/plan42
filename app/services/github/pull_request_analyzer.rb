require "json"

module Github
  class PullRequestAnalyzer
    Result = Struct.new(:completed, :additional, :raw_response, keyword_init: true)

    def initialize(payload:, creative:, paths:, client: GeminiChatClient.new, logger: Rails.logger)
      @payload = payload
      @creative = creative
      @paths = paths
      @client = client
      @logger = logger
    end

    def call
      response_text = collect_response
      return unless response_text.present?

      parsed = parse_response(response_text)
      Result.new(
        completed: Array(parsed["completed"]).map(&:to_s),
        additional: Array(parsed["additional"]).map(&:to_s),
        raw_response: response_text
      )
    rescue StandardError => e
      logger.error("Gemini analysis failed: #{e.class} #{e.message}")
      nil
    end

    private

    attr_reader :payload, :creative, :paths, :client, :logger

    def collect_response
      messages = build_messages
      buffer = +""
      client.chat(messages) do |delta|
        buffer << delta.to_s
      end
      buffer
    rescue StandardError => e
      logger.error("Gemini chat failed: #{e.class} #{e.message}")
      nil
    end

    def build_messages
      pr = payload["pull_request"]
      tree_lines = paths.map { |path| "- #{path}" }.join("\n")
      pr_body = pr["body"].to_s

      prompt = <<~PROMPT
        You are reviewing a GitHub pull request and mapping it to Creative tasks.
        Pull request title: #{pr["title"]}
        Pull request body:
        #{pr_body}

        Creative task paths (each line is a single task path from root to leaf):
        #{tree_lines}

        Return a JSON object with two keys:
        - "completed": array of task paths from the provided list that this PR completes.
        - "additional": array of task paths (existing or new suggestions) that should be tackled next.
        Respond with valid JSON only.
      PROMPT

      [ { role: "user", parts: [ { text: prompt } ] } ]
    end

    def parse_response(text)
      json_fragment = extract_json(text)
      JSON.parse(json_fragment)
    rescue JSON::ParserError => e
      logger.warn("Failed to parse Gemini response as JSON: #{e.message}")
      { "completed" => [], "additional" => [], "raw" => text }
    end

    def extract_json(text)
      start_index = text.index("{")
      end_index = text.rindex("}")
      return text unless start_index && end_index && end_index >= start_index

      text[start_index..end_index]
    end
  end
end
