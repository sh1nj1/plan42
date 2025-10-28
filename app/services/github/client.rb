module Github
  class Client
    def initialize(account)
      @client = Octokit::Client.new(access_token: account.token)
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

    private

    attr_reader :client
  end
end
