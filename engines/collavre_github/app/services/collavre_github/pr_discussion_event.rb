module CollavreGithub
  class PrDiscussionEvent
    Definition = Data.define(:resource, :action, :handler, :endpoint, :timestamp)

    EVENTS = {
      "issue_comment" => Definition.new("comment", "created", :handle_issue_comment, "issues/%s/comments", "created_at"),
      "pull_request_review_comment" => Definition.new("comment", "created", :handle_review_comment, "pulls/%s/comments", "created_at"),
      "pull_request_review" => Definition.new("review", "submitted", :handle_review_submitted, "pulls/%s/reviews", "submitted_at")
    }.freeze

    def self.poll(client, repo, number, since:)
      EVENTS.flat_map do |event, definition|
        client.pull_request_discussion(repo, format(definition.endpoint, number)).filter_map do |resource|
          timestamp = resource[definition.timestamp]&.to_time
          next unless resource["id"].present? && timestamp && timestamp >= since

          resource["state"] = resource["state"].to_s.downcase if definition.resource == "review"
          payload = { "action" => definition.action, definition.resource => resource }
          payload["issue"] = { "number" => number, "pull_request" => {} } if event == "issue_comment"
          [ timestamp, event, payload ]
        end
      end.sort_by(&:first)
    end
  end
end
