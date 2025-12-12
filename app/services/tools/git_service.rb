require "sorbet-runtime"
require "open3"
require "pathname"
require "uri"
require "fileutils"
require "rails_mcp_engine"

module Tools
  class GitService
    extend T::Sig
    extend ToolMeta

    tool_name "git"
    tool_description "Execute local git commands."

    tool_param :action, description: "Operation to perform. Use 'clone' to clone a repository. Defaults to 'clone'."
    tool_param :repo, description: "Repository info for clone action: { url: 'https://github.com/owner/repo', pat: '<token>' }."
    tool_param :root_path, description: "Optional path for the repository root (e.g., 'repos/plan42'). Relative paths are resolved from Rails.root."

    sig do
      params(
        action: String,
        repo: T.nilable(T::Hash[T.any(String, Symbol), T.untyped]),
        root_path: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(action: "clone", repo: nil, root_path: nil)
      repo_root = resolve_root_path(root_path)

      case action
      when "clone"
        clone_repository(repo_root: repo_root, repo: repo)
      else
        { type: "error", error: "Unsupported action '#{action}'. Use 'clone'." }
      end
    end

    private

    sig { params(root_path: T.nilable(String)).returns(Pathname) }
    def resolve_root_path(root_path)
      base_root = Pathname.new(root_path.presence || Rails.root.to_s)
      base_root = Rails.root.join(base_root) unless base_root.absolute?
      normalized = base_root.cleanpath

      # For git operations, the root might not exist yet (e.g. before clone),
      # so we check the parent directory if the path doesn't exist.
      check_path = normalized
      until check_path.exist? || check_path.root?
        check_path = check_path.parent
      end

      # Resolve to real path to handle symlinks
      begin
        real_check_path = check_path.realpath
      rescue Errno::ENOENT
        raise ArgumentError, "Parent directory does not exist"
      end

      unless real_check_path.to_s.start_with?(Rails.root.realpath.to_s)
        raise ArgumentError, "root_path must be inside the Rails application root"
      end

      normalized
    end

    sig do
      params(repo_root: Pathname, repo: T.nilable(T::Hash[T.any(String, Symbol), T.untyped])).returns(T::Hash[Symbol, T.untyped])
    end
    def clone_repository(repo_root:, repo:)
      url = repo&.dig(:url) || repo&.dig("url")
      pat = repo&.dig(:pat) || repo&.dig("pat")

      raise ArgumentError, "repo.url is required for clone action" if url.blank?

      destination_dir = repo_root
      
      # Security check: Ensure destination is within Rails root
      # We re-verify here because resolve_root_path allows non-existent paths (for cloning into new dirs)
      # but we want to be extra sure the final resolved path is safe.
      absolute_dest = destination_dir.cleanpath
      
      # Find the existing parent to check realpath
      check_path = absolute_dest
      until check_path.exist? || check_path.root?
        check_path = check_path.parent
      end
      
      begin
        real_check_path = check_path.realpath
      rescue Errno::ENOENT
        raise ArgumentError, "Parent directory does not exist"
      end

      unless real_check_path.to_s.start_with?(Rails.root.realpath.to_s)
        raise ArgumentError, "Destination must be inside the Rails application root"
      end

      FileUtils.mkdir_p(destination_dir.parent)

      url_with_token = build_authenticated_url(url, pat)
      command = [ "git", "clone", url_with_token, destination_dir.to_s ]
      stdout_str, stderr_str, status = Open3.capture3({ "GIT_TERMINAL_PROMPT" => "0" }, *command)

      sanitized_stderr = mask_secret(stderr_str, pat)
      sanitized_stdout = mask_secret(stdout_str, pat)

      if status.success?
        {
          type: "clone",
          url: mask_secret(url, pat),
          destination: destination_dir.relative_path_from(Rails.root).to_s,
          message: mask_secret(stdout_str.presence || "clone completed", pat)
        }
      else
        {
          type: "clone",
          url: mask_secret(url, pat),
          destination: destination_dir.relative_path_from(Rails.root).to_s,
          error: sanitized_stderr.presence || sanitized_stdout.presence || "git clone failed",
          status: status.exitstatus
        }
      end
    end

    sig { params(url: String, pat: T.nilable(String)).returns(String) }
    def build_authenticated_url(url, pat)
      return url if pat.blank?

      begin
        parsed = URI.parse(url)
        parsed.userinfo = pat
        parsed.to_s
      rescue URI::InvalidURIError
        url
      end
    end

    sig { params(text: T.nilable(String), secret: T.nilable(String)).returns(T.nilable(String)) }
    def mask_secret(text, secret)
      return text if secret.blank? || text.blank?

      text.gsub(secret, "[REDACTED]")
    end
  end
end
