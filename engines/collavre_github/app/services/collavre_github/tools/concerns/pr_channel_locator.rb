# frozen_string_literal: true

module CollavreGithub
  module Tools
    module Concerns
      # Shared PR-URL parsing and channel lookup for the PR-channel tools
      # (pr_monitor attaches, pr_state_set corrects). Both must agree on how a
      # URL maps to a stored channel or a state correction would silently miss
      # the very channel the monitor created.
      module PrChannelLocator
        extend ActiveSupport::Concern

        PR_URL_RE = %r{\Ahttps?://github\.com/([^/]+/[^/]+)/pull/(\d+)\z}.freeze

        private

        # GitHub owner/repo identifiers are case-insensitive but webhook
        # payloads always carry the canonical case. Normalize on parse so user
        # input like "Owner/Repo" still matches incoming events.
        #
        # @return [[String, Integer]] downcased repo full name and PR number
        def parse_pr_url(pr_url)
          m = pr_url.to_s.match(PR_URL_RE)
          raise ArgumentError, "Invalid PR URL: #{pr_url}" unless m

          [ m[1].downcase, m[2].to_i ]
        end

        # Ruby-level compare instead of a WHERE: legacy rows can carry
        # mixed-case repo names, and the dispatch path matches the same way.
        def lookup_channel(topic, repo, pr_number)
          CollavreGithub::GithubPrChannel.where(topic_id: topic.id).find do |c|
            c.repo_full_name.to_s.downcase == repo.downcase && c.pr_number == pr_number
          end
        end

        # Creatives whose RepositoryLinks govern this topic: the topic's own
        # creative plus its ancestors. Mirrors pr_monitor's provisioning scope,
        # so a tool can never reach a GitHub account the monitor itself could
        # not have used.
        def scoped_creative_ids(topic)
          creative = topic.creative
          return [] unless creative

          [ creative.id ] + creative.ancestors.pluck(:id)
        end
      end
    end
  end
end
