# frozen_string_literal: true

module CollavreGithub
  module Tools
    module Concerns
      # Shared logic for finding GitHub client from Creative context
      module GithubClientFinder
        extend ActiveSupport::Concern

        private

        # Find GitHub client for a creative and repository
        # Traverses from creative to its origin, then finds the linked repository
        #
        # @param creative_id [Integer] The creative ID to start from
        # @param repo [String] Repository full name (e.g., "owner/repo")
        # @return [CollavreGithub::Client, nil] GitHub client or nil if not found
        def find_github_client(creative_id, repo)
          creative = Collavre::Creative.find_by(id: creative_id)
          return nil unless creative

          origin = creative.effective_origin
          link = CollavreGithub::RepositoryLink
            .joins(:creative)
            .where(repository_full_name: repo)
            .where(creative: origin.self_and_descendants)
            .first

          return nil unless link&.github_account

          CollavreGithub::Client.new(link.github_account)
        end
      end
    end
  end
end
