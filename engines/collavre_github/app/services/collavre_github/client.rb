module CollavreGithub
  class Client
    MOCK_SERVER_DEFAULT = "http://localhost:4567"

    def initialize(account)
      options = { access_token: account.token }
      api_endpoint = resolve_api_endpoint
      options[:api_endpoint] = api_endpoint if api_endpoint.present?
      @client = Octokit::Client.new(options)
      @client.auto_paginate = true
    end

    def organizations
      client.organizations
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub organizations fetch failed: #{e.message}")
      []
    end

    def repositories_for_authenticated_user
      client.repos(nil, type: "all")
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub user repos fetch failed: #{e.message}")
      []
    end

    def repositories_for_organization(org)
      client.org_repos(org, type: "all")
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub org repos fetch failed: #{e.message}")
      []
    end

    def pull_request_details(repo_full_name, number)
      client.pull_request(repo_full_name, number)
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub PR fetch failed: #{e.message}")
      nil
    end

    def pull_request_commit_messages(repo_full_name, number)
      client
        .pull_request_commits(repo_full_name, number)
        .map { |commit| commit.commit&.message }
        .compact
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub PR commits fetch failed: #{e.message}")
      []
    end

    def pull_request_diff(repo_full_name, number)
      files = client.pull_request_files(repo_full_name, number)
      formatted = files.filter_map do |file|
        next unless file.patch.present?

        <<~DIFF.strip
          diff --git a/#{file.filename} b/#{file.filename}
          #{file.patch}
        DIFF
      end
      formatted.join("\n\n").presence
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub PR files fetch failed: #{e.message}")
      nil
    end

    def repository_hooks(repo_full_name)
      client.hooks(repo_full_name)
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub hooks fetch failed for #{repo_full_name}: #{e.message}")
      []
    end

    def create_repository_webhook(repo_full_name, url:, secret:, events:, content_type: "json")
      client.create_hook(
        repo_full_name,
        "web",
        {
          url: url,
          content_type: content_type,
          secret: secret
        },
        {
          events: events,
          active: true
        }
      )
    end

    def update_repository_webhook(repo_full_name, hook_id, url:, secret:, events:, content_type: "json")
      client.edit_hook(
        repo_full_name,
        hook_id,
        "web",
        {
          url: url,
          content_type: content_type,
          secret: secret
        },
        {
          events: events,
          active: true
        }
      )
    end

    def delete_repository_webhook(repo_full_name, hook_id)
      client.remove_hook(repo_full_name, hook_id)
    end

    # Fetch the default branch name for a repository
    def default_branch(repo_full_name)
      repo = client.repository(repo_full_name)
      repo.default_branch
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub default branch fetch failed: #{e.message}")
      "main"
    end

    # Fetch the full recursive tree for a given branch/sha
    def tree(repo_full_name, branch)
      sha = client.ref(repo_full_name, "heads/#{branch}").object.sha
      result = client.tree(repo_full_name, sha, recursive: true)
      result.tree
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub tree fetch failed: #{e.message}")
      []
    end

    # Fetch file content (decoded) for a given path and ref
    def file_content(repo_full_name, path, ref: nil)
      opts = ref ? { ref: ref } : {}
      content = client.contents(repo_full_name, path: path, **opts)
      if content.encoding == "base64"
        Base64.decode64(content.content).force_encoding("UTF-8")
      else
        content.content
      end
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub file content fetch failed for #{path}: #{e.message}")
      nil
    end

    # Compare two commits and return changed files
    def compare(repo_full_name, base, head)
      client.compare(repo_full_name, base, head)
    rescue Octokit::Error, Faraday::Error => e
      Rails.logger.warn("GitHub compare failed: #{e.message}")
      nil
    end

    private

    attr_reader :client

    # Use GITHUB_API_ENDPOINT env var if set, otherwise fall back to mock server
    # in development when no real GitHub credentials are configured.
    def resolve_api_endpoint
      return ENV["GITHUB_API_ENDPOINT"] if ENV["GITHUB_API_ENDPOINT"].present?

      if Rails.env.development? && ENV["GITHUB_CLIENT_ID"].blank?
        MOCK_SERVER_DEFAULT
      end
    end
  end
end
