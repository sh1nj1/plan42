# frozen_string_literal: true

require "test_helper"

module CollavreGithub
  module Tools
    class GithubPrDiffServiceTest < ActiveSupport::TestCase
      SERVICE_CLASS = GithubPrDiffService
      include GithubPrServiceTestSetup

      test "has default max length constant" do
        assert_equal 10_000, GithubPrDiffService::DIFF_MAX_LENGTH
      end
    end
  end
end
