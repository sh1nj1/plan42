module CollavreSlack
  module ErrorLoggable
    extend ActiveSupport::Concern

    private

    # Wraps a block with standardized Slack error handling.
    # Logs the error message and first 5 backtrace lines.
    #
    # @param context_name [String] identifies the caller in the log (e.g. "SlackMessageJob")
    # @param reraise [Boolean] whether to re-raise after logging (default: false)
    # @yield the block to execute with error handling
    def with_slack_error_handling(context_name, reraise: false)
      yield
    rescue StandardError => e
      Rails.logger.error("[CollavreSlack] #{context_name} error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      raise if reraise
    end
  end
end
