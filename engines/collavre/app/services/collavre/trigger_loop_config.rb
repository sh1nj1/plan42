# frozen_string_literal: true

module Collavre
  module TriggerLoopConfig
    def self.build(topic_id, **options)
      {
        "state" => "running", "current_iteration" => 0, "max_iterations" => 10,
        "completion_conditions" => [], "stuck_conditions" => [], "on_retry" => "continue",
        "last_task_id" => nil, "cooldown_seconds" => 10, "trigger_topic_id" => topic_id
      }.merge(options.stringify_keys).tap do |config|
        config["generation"] ||= 1 if config["source"] == "keep"
      end
    end
  end
end
