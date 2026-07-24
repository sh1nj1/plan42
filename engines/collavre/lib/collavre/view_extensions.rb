# frozen_string_literal: true

module Collavre
  # ViewExtensions provides a registry for engines to register UI components
  # into named extension slots in core views. This avoids core views needing
  # to check `defined?(SomeEngine)` and enables a clean plugin architecture.
  #
  # Usage in engine initializers:
  #   Collavre::ViewExtensions.register(:creative_toolbar, partial: "collavre_plan/creatives/set_plan_button")
  #   Collavre::ViewExtensions.register(:creative_modals, partial: "collavre/creatives/set_plan_modal")
  #   Collavre::ViewExtensions.register(:navigation_panels, partial: "collavre_plan/shared/navigation/panels")
  #
  # Usage in core views:
  #   <%= render_extension_slot(:creative_toolbar) %>
  #   <%= render_extension_slot(:creative_modals, locals: { parent: @parent_creative }) %>
  #
  class ViewExtensions
    include Singleton

    def initialize
      @slots = {}
      @mutex = Mutex.new
    end

    # Register a partial into a named slot
    # @param slot [Symbol] the extension slot name
    # @param partial [String] the partial path to render
    # @param priority [Integer] lower = rendered first (default 100)
    def self.register(slot, partial:, priority: 100)
      instance.register(slot, partial: partial, priority: priority)
    end

    # Unregister a partial from a slot
    def self.unregister(slot, partial:)
      instance.unregister(slot, partial: partial)
    end

    # Get all registered partials for a slot, sorted by priority
    def self.for_slot(slot)
      instance.for_slot(slot)
    end

    # Clear all registrations (for testing)
    def self.reset!
      instance.reset!
    end

    def register(slot, partial:, priority: 100)
      @mutex.synchronize do
        @slots[slot.to_sym] ||= []
        @slots[slot.to_sym].reject! { |entry| entry[:partial] == partial }
        @slots[slot.to_sym] << { partial: partial, priority: priority }
        @slots[slot.to_sym].sort_by! { |entry| entry[:priority] }
      end
    end

    def unregister(slot, partial:)
      @mutex.synchronize do
        @slots[slot.to_sym]&.reject! { |entry| entry[:partial] == partial }
      end
    end

    def for_slot(slot)
      @mutex.synchronize do
        (@slots[slot.to_sym] || []).dup
      end
    end

    def reset!
      @mutex.synchronize do
        @slots = {}
      end
    end
  end
end
