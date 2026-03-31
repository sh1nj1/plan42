# frozen_string_literal: true

module Collavre
  class TriggerStatusComponent < ViewComponent::Base
    # Renders a circular progress indicator for trigger loop state,
    # or a trigger activation toggle for containers.
    #
    # creative_role:
    #   :container  — parent with drop trigger (shows toggle)
    #   :task       — child with loop state (shows circular progress + action)
    #   :none       — neither (shows nothing)

    STATES = %w[idle running pending_verification completed stuck max_reached paused].freeze

    def initialize(creative:, can_write: false)
      @creative = creative
      @can_write = can_write
      @trigger_data = creative.data&.dig("trigger") || {}
      @loop_data = @trigger_data["loop"] || {}
      @role = determine_role
    end

    def render?
      @role != :none
    end

    private

    def determine_role
      if @loop_data["state"].present?
        :task
      elsif @creative.parent_id.present? && @trigger_data.empty?
        # Child without any trigger data — could become a container or nothing
        :none
      else
        # Has trigger config or is a potential container
        :container
      end
    end

    def state
      @loop_data["state"] || "idle"
    end

    def current_iteration
      @loop_data["current_iteration"] || 0
    end

    def max_iterations
      @loop_data["max_iterations"] || 10
    end

    def progress_ratio
      return 1.0 if %w[completed max_reached].include?(state)
      return 0.0 if state == "idle"

      max = max_iterations.to_f
      return 0.0 if max.zero?

      (current_iteration.to_f / max).clamp(0.0, 1.0)
    end

    def color_token
      case state
      when "idle" then "var(--text-muted)"
      when "running" then "var(--color-active)"
      when "pending_verification" then "var(--color-warning)"
      when "completed" then "var(--color-success)"
      when "stuck" then "var(--color-danger)"
      when "max_reached" then "var(--color-warning)"
      when "paused" then "var(--text-muted)"
      else "var(--text-muted)"
      end
    end

    def container_enabled?
      @trigger_data["on_child_enter"] == true
    end
  end
end
