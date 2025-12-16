require "json"

module Github
  class PullRequestAnalyzer
    Result = Struct.new(:completed, :additional, :raw_response, :prompt, keyword_init: true)
    CompletedTask = Struct.new(:creative_id, :progress, :note, :path, keyword_init: true)
    SuggestedTask = Struct.new(:parent_id, :description, :progress, :note, :path, keyword_init: true)

    DIFF_MAX_LENGTH = 10_000

    def initialize(payload:, creative:, paths:, commit_messages: [], diff: nil, client: GeminiChatClient.new, logger: Rails.logger)
      @payload = payload
      @creative = creative
      @paths = normalize_paths(paths)
      @commit_messages = Array(commit_messages)
      @diff = diff
      @client = client
      @logger = logger
      @prompt_text = nil
    end

    def call
      response_text = collect_response
      return unless response_text.present?

      parsed = parse_response(response_text)
      Result.new(
        completed: parsed[:completed],
        additional: parsed[:additional],
        raw_response: response_text,
        prompt: prompt_text
      )
    rescue StandardError => e
      logger.error("Gemini analysis failed: #{e.class} #{e.message}")
      nil
    end

    private

    attr_reader :payload, :creative, :paths, :commit_messages, :diff, :client, :logger, :prompt_text

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

      # Use shared TreeFormatter logic
      tree_lines = Creatives::TreeFormatter.new.format(creative)

      pr_body = pr["body"].to_s
      commit_lines = formatted_commit_messages
      diff_text = formatted_diff
      language_instructions = preferred_language_instructions

      prompt_template = creative.github_gemini_prompt_template
      prompt = render_prompt_template(
        prompt_template,
        pr_title: pr["title"].to_s,
        pr_body: pr_body,
        commit_messages: commit_lines,
        diff: diff_text,
        creative_tree: tree_lines,
        language_instructions: language_instructions
      )

      @prompt_text = prompt
      [ { role: "user", parts: [ { text: prompt } ] } ]
    end

    def normalize_paths(paths)
      Array(paths).map do |entry|
        case entry
        when Hash
          path_value = entry[:path]
          path_value = entry["path"] if path_value.nil?

          leaf_value =
            if entry.key?(:leaf)
              entry[:leaf]
            elsif entry.key?("leaf")
              entry["leaf"]
            end

          {
            path: path_value.to_s,
            leaf: !!leaf_value
          }
        else
          { path: entry.to_s, leaf: false }
        end
      end
    end

    def parse_response(text)
      json_fragment = extract_json(text)
      data = JSON.parse(json_fragment)
      {
        completed: sanitize_completed(data["completed"]),
        additional: sanitize_additional(data["additional"])
      }
    rescue JSON::ParserError => e
      logger.warn("Failed to parse Gemini response as JSON: #{e.message}")
      { completed: [], additional: [] }
    end

    def extract_json(text)
      start_index = text.index("{")
      end_index = text.rindex("}")
      return text unless start_index && end_index && end_index >= start_index

      text[start_index..end_index]
    end

    def formatted_commit_messages
      return "No commit messages available." if commit_messages.blank?

      commit_messages.map.with_index(1) do |message, index|
        "#{index}. #{message.to_s.strip}"
      end.join("\n")
    end

    def formatted_diff
      return "(No diff available)" if diff.blank?

      diff_text = diff.to_s.strip
      return "(No diff available)" if diff_text.empty?

      return diff_text if diff_text.length <= DIFF_MAX_LENGTH

      truncated = diff_text.slice(0, DIFF_MAX_LENGTH)
      "#{truncated}\n...\n[Diff truncated to #{DIFF_MAX_LENGTH} characters]"
    end

    def preferred_language_instructions
      language = preferred_response_language
      "Preferred response language: #{language[:label]} (#{language[:code]}). Write all natural-language output, including new creative descriptions, in #{language[:label]}."
    end

    def preferred_response_language
      locale = creative.user&.locale.presence
      locale ||= I18n.default_locale.to_s if defined?(I18n)
      locale ||= "en"

      label = if defined?(I18n)
                I18n.t("users.locales.#{locale}", default: locale)
      else
                locale
      end

      { code: locale, label: label }
    end

    def render_prompt_template(template, variables)
      template.to_s.gsub(/\#\{([^}]+)\}/) do
        key = Regexp.last_match(1).strip.to_sym
        value = variables.fetch(key, "")
        value.to_s
      end
    end

    def sanitize_completed(items)
      Array(items).filter_map do |item|
        case item
        when Hash
          creative_id = extract_creative_id(item["creative_id"] || item["id"])
          next unless creative_id

          CompletedTask.new(
            creative_id: creative_id,
            progress: normalize_progress(item["progress"], default: 1.0),
            note: string_presence(item["note"] || item["summary"]),
            path: string_presence(item["path"] || item["description"])
          )
        when Integer
          CompletedTask.new(creative_id: item, progress: 1.0)
        when String
          creative_id = extract_id_from_string(item)
          next unless creative_id

          CompletedTask.new(
            creative_id: creative_id,
            progress: 1.0,
            path: string_presence(item)
          )
        else
          nil
        end
      end
    end

    def sanitize_additional(items)
      Array(items).filter_map do |item|
        case item
        when Hash
          parent_id = extract_creative_id(item["parent_id"] || item["parent"])
          description = string_presence(item["description"] || item["title"])
          next unless parent_id && description

          SuggestedTask.new(
            parent_id: parent_id,
            description: description,
            progress: normalize_progress(item["progress"], default: nil),
            note: string_presence(item["note"] || item["summary"]),
            path: string_presence(item["path"])
          )
        when String
          parent_id = extract_id_from_string(item)
          next unless parent_id

          description = item.sub(/^.*\]\s*/, "").strip
          description = item if description.blank?

          SuggestedTask.new(parent_id: parent_id, description: description, progress: nil)
        else
          nil
        end
      end
    end

    def extract_creative_id(value)
      case value
      when Integer
        value.positive? ? value : nil
      when Float
        int_value = value.to_i
        int_value.positive? ? int_value : nil
      when String
        match = value.match(/\d+/)
        match ? match[0].to_i : nil
      else
        nil
      end
    end

    def normalize_progress(value, default: nil)
      return default if value.nil?

      float_value = Float(value) rescue nil
      return default unless float_value

      [ [ float_value, 0.0 ].max, 1.0 ].min
    end

    def string_presence(value)
      return if value.nil?

      str = value.to_s.strip
      str.presence
    end

    def extract_id_from_string(value)
      return unless value.is_a?(String)

      matches = value.scan(/\[(\d+)\]/).flatten
      return if matches.blank?

      matches.last.to_i
    end
  end
end
