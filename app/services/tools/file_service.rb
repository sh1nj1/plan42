require "sorbet-runtime"
require "open3"
require "pathname"
require "rails_mcp_engine"

module Tools
  class FileService
    extend T::Sig
    extend ToolMeta

    tool_name "file"
    tool_description "Search files and read content using rg."

    tool_param :action, description: "Operation to perform. Use 'search' to search for text or 'read' to read file content. Defaults to 'search'."
    tool_param :query, description: "Text to search for in the repository. Required for 'search' action."
    tool_param :file_path, description: "Relative path of a file to read. Required for 'read' action."
    tool_param :start_line, description: "Line number to start reading from when returning file content. Defaults to 1."
    tool_param :line_count, description: "How many lines of file content to return. Defaults to 120; capped at 400 lines."
    tool_param :max_results, description: "Maximum number of search matches to return when running a text search. Defaults to 20."
    tool_param :root_path, description: "Optional path for the repository root. Relative paths are resolved from Rails.root."

    sig do
      params(
        action: String,
        query: T.nilable(String),
        file_path: T.nilable(String),
        start_line: Integer,
        line_count: Integer,
        max_results: Integer,
        root_path: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(action: "search", query: nil, file_path: nil, start_line: 1, line_count: 120, max_results: 20, root_path: nil)
      repo_root = resolve_root_path(root_path)

      case action
      when "search"
        raise ArgumentError, "query is required for search action" if query.blank?
        search_repository(repo_root: repo_root, query: query, max_results: max_results)
      when "read"
        raise ArgumentError, "file_path is required for read action" if file_path.blank?
        read_file(repo_root: repo_root, file_path: file_path, start_line: start_line, line_count: line_count)
      else
        { type: "error", error: "Unsupported action '#{action}'. Use 'search' or 'read'." }
      end
    end

    private

    sig { params(root_path: T.nilable(String)).returns(Pathname) }
    def resolve_root_path(root_path)
      base_root = Pathname.new(root_path.presence || Rails.root.to_s)
      base_root = Rails.root.join(base_root) unless base_root.absolute?
      normalized = base_root.cleanpath

      # Resolve to real path to handle symlinks and ensure we are checking the actual location
      begin
        real_root = normalized.realpath
      rescue Errno::ENOENT
        raise ArgumentError, "Root path does not exist"
      end

      unless real_root.to_s.start_with?(Rails.root.realpath.to_s)
        raise ArgumentError, "root_path must be inside the Rails application root"
      end

      real_root
    end

    sig do
      params(repo_root: Pathname, query: String, max_results: Integer).returns(T::Hash[Symbol, T.untyped])
    end
    def search_repository(repo_root:, query:, max_results:)
      sanitized_max = [ [ max_results, 1 ].max, 200 ].min
      command = [
        "rg",
        "--line-number",
        "--color",
        "never",
        "--max-count",
        sanitized_max.to_s,
        query,
        repo_root.to_s
      ]

      stdout_str, stderr_str, status = Open3.capture3(*command)

      if status.exitstatus.positive? && stdout_str.blank?
        return { type: "search", query: query, results: [], error: status.exitstatus == 2 ? stderr_str : nil }
      end

      results = []

      stdout_str.each_line do |line|
        break if results.length >= sanitized_max
        
        # rg output format: file_path:line_number:content
        # We need to handle potential colons in filename or content, but standard rg output is usually reliable for this regex
        match_data = line.match(/^(.*?):(\d+):(.*)$/)
        next unless match_data

        absolute_path = Pathname.new(match_data[1])
        relative_path = absolute_path.relative_path_from(repo_root).to_s rescue match_data[1]

        results << {
          file_path: relative_path,
          line: match_data[2].to_i,
          preview: match_data[3].strip
        }
      end

      {
        type: "search",
        query: query,
        results: results,
        truncated: results.length >= sanitized_max
      }
    end

    sig do
      params(repo_root: Pathname, file_path: String, start_line: Integer, line_count: Integer).returns(T::Hash[Symbol, T.untyped])
    end
    def read_file(repo_root:, file_path:, start_line:, line_count:)
      sanitized_start = [ start_line, 1 ].max
      sanitized_count = [ [ line_count, 1 ].max, 400 ].min

      root_realpath = repo_root.realpath
      absolute_path = Pathname.new(file_path)
      absolute_path = repo_root.join(absolute_path) unless absolute_path.absolute?
      absolute_path = absolute_path.cleanpath

      resolved_path = begin
        absolute_path.realpath
      rescue Errno::ENOENT
        return { type: "file", error: "File not found" }
      end

      unless resolved_path.to_s.start_with?(root_realpath.to_s)
        return { type: "file", error: "File path must be inside the repository" }
      end

      unless resolved_path.file?
        return { type: "file", error: "File not found" }
      end

      lines = ::File.readlines(resolved_path)
      slice = lines.slice(sanitized_start - 1, sanitized_count) || []

      {
        type: "file",
        file_path: resolved_path.relative_path_from(root_realpath).to_s,
        start_line: sanitized_start,
        end_line: sanitized_start + slice.length - 1,
        content: slice.join
      }
    rescue => e
      { type: "file", error: e.message }
    end
  end
end
