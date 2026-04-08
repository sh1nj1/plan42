# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Tools
    class GithubPrCommitsServiceTest < ActiveSupport::TestCase
      SERVICE_CLASS = GithubPrCommitsService
      include GithubPrServiceTestSetup
    end
  end
end
