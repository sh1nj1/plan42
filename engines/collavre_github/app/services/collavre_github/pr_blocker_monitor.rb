module CollavreGithub
  class PrBlockerMonitor
    FAILURE_CONCLUSIONS = %w[failure timed_out startup_failure action_required].freeze
    FAILURE_STATES = %w[error failure].freeze

    def initialize(channel)
      @channel = channel
    end

    def call
      repo = channel.repo_full_name
      number = channel.pr_number
      link = repository_link(repo)
      return unless link

      client = Client.new(link.github_account)
      pr = client.pull_request_details(repo, number)
      return unless pr&.state == "open" && pr.base.repo.id.to_s == link.repository_id.to_s

      head = pr.head.sha
      return if head.blank?

      poll_updates(client, link, pr, repo, number)
    end

    private

    attr_reader :channel

    def poll_updates(client, link, pr, repo, number)
      since = channel.discussion_poll_since
      discussion = PrDiscussionEvent.poll(client, repo, number, since: since)
      failures = check_failures(client, repo, pr.head.sha)
      channel.with_lock do
        next unless monitoring?(repo, number)
        next unless repository_link(repo)&.repository_id == link.repository_id

        channel.start_discussion_tracking!(since)
        record_blockers(pr.head.sha, pr.mergeable, failures)
        discussion.each do |_timestamp, event, payload|
          channel.deliver_event!(event: event, payload: payload)
        end
      end
    end

    def monitoring?(repo, number)
      channel.active? && !channel.dismissed? && channel.pr_state == "open" &&
        channel.repo_full_name == repo && channel.pr_number == number
    end

    def repository_link(repo)
      creative = channel.topic.reload.creative
      links = RepositoryLink.where(creative_id: [ creative.id ] + creative.ancestors.pluck(:id))
        .where("LOWER(repository_full_name) = ?", repo.to_s.downcase)
        .includes(:github_account).to_a
      repo_ids = links.map(&:repository_id).uniq
      links.first if repo_ids.one? && repo_ids.first.present?
    end

    def check_failures(client, repo, head)
      runs = client.pull_request_check_runs(repo, head).filter_map do |run|
        next unless run.status == "completed" && FAILURE_CONCLUSIONS.include?(run.conclusion)

        [ "run:#{run.id}:#{run.completed_at}", run.name ]
      end
      statuses = client.pull_request_commit_statuses(repo, head).filter_map do |status|
        next unless FAILURE_STATES.include?(status.state)

        [ "status:#{status.id}", status.context ]
      end
      (runs + statuses).to_h
    end

    def record_blockers(head, mergeable, failures)
      previous = channel.config.fetch("pr_blockers", {})
      notified = previous["head"] == head ? previous.fetch("check_ids", []) : []
      new_failures = failures.except(*notified)
      conflict = mergeable.nil? ? previous["conflict"] : !mergeable

      if conflict && !previous["conflict"]
        channel.inject_into_topic!(channel.blocker_message("merge_conflict_message"))
      end
      if new_failures.any?
        channel.inject_into_topic!(
          channel.blocker_message("failed_checks_message", checks: new_failures.values.map(&:squish).uniq.join(", "))
        )
      end

      current = { "head" => head, "conflict" => conflict, "check_ids" => notified | failures.keys }
      channel.update!(config: channel.config.merge("pr_blockers" => current)) if current != previous
    end
  end
end
