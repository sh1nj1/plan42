module CollavreGithub
  class PrBlockerSweepJob < ApplicationJob
    queue_as :default

    limits_concurrency to: 1,
      key: -> { "github-pr-blocker-sweep" },
      duration: 1.hour,
      on_conflict: :discard

    def perform
      GithubPrChannel.active.not_dismissed.find_each do |channel|
        PrBlockerMonitor.new(channel).call
      rescue StandardError => e
        Rails.logger.warn("[CollavreGithub] PR blocker check failed for channel #{channel.id}: #{e.class}")
      end
    end
  end
end
