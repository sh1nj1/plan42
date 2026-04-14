module Collavre
  require "json"

  module Comments
    class McpCommand
      def initialize(comment:, user:, tool:, creative: nil, meta_tool_service: default_meta_tool_service)
        @comment = comment
        @user = user
        @tool = tool
        @creative = creative
        @meta_tool_service = meta_tool_service
      end

      def call
        return unless command_match?

        arguments = parsed_arguments
        return usage_message unless arguments

        response = meta_tool_service.call(action: "run", tool_name: tool_name, arguments: arguments)
        format_response(response)
      rescue StandardError => e
        Rails.logger.error("MCP command '#{tool_name}' failed: #{e.message}")
        e.message
      end

      private

      attr_reader :comment, :user, :tool, :creative, :meta_tool_service

      def command_match?
        comment.content.to_s.strip.match?(command_pattern)
      end

      def command_pattern
        @command_pattern ||= /\A\/#{Regexp.escape(tool_name)}\b/i
      end

      def command_body
        comment.content.to_s.strip.sub(command_pattern, "").strip
      end

      def parsed_arguments
        body = command_body
        explicit_args = if body.blank?
          {}
        else
          begin
            JSON.parse(body)
          rescue JSON::ParserError
            key_value_arguments(body)
          end
        end

        merge_with_defaults(explicit_args)
      end

      def key_value_arguments(body)
        args = body.split(/\s+/).each_with_object({}) do |pair, result|
          key, value = pair.split("=", 2)
          next if key.blank? || value.nil?

          result[key] = cast_value(value)
        end

        return args if args.present?

        nil
      end

      def merge_with_defaults(explicit_args)
        return explicit_args unless explicit_args.is_a?(Hash)

        defaults = creative&.data&.dig("tools", tool_name)
        return explicit_args unless defaults.is_a?(Hash)

        defaults.merge(explicit_args)
      end

      def cast_value(value)
        case value
        when /\A\d+\z/ then value.to_i
        when /\A\d+\.\d+\z/ then value.to_f
        when /\Atrue\z/i then true
        when /\Afalse\z/i then false
        else
          value
        end
      end

      def usage_message
        params = Array(tool[:params]).map { |param| param[:name] }.join(" ").presence
        usage = [ tool_name, params ].compact.join(" ")
        "Usage: /#{usage}"
      end

      def format_response(response)
        return I18n.t("collavre.comments.mcp_command.error_running", tool_name: tool_name, error: response[:error]) if response[:error].present?

        result = response[:result]
        content = case result
        when Hash, Array
          JSON.pretty_generate(result)
        else
          result.to_s
        end

        escaped_tool = ERB::Util.html_escape(tool_name)
        escaped_content = ERB::Util.html_escape(content)

        <<~HTML
        <details><summary>#{escaped_tool} response</summary>
        <pre><code>#{escaped_content}</code></pre>
        </details>
        HTML
      end

      def tool_name
        tool[:name]
      end

      def default_meta_tool_service
        ::Tools::MetaToolService.new
      end
    end
  end
end
