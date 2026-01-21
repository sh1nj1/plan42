# frozen_string_literal: true

module Navigation
  class Registry
    include Singleton

    DEFAULT_PRIORITY = 500
    DEFAULT_SECTION = :main

    def initialize
      @items = []
      @mutex = Mutex.new
    end

    # Register a new navigation item or replace an existing one with the same key
    def register(item)
      item = normalize_item(item)
      validate_item!(item)

      @mutex.synchronize do
        # Remove existing item with same key if present
        @items.reject! { |i| i[:key] == item[:key] }
        @items << item
      end
      item
    end

    # Remove an item by key
    def unregister(key)
      @mutex.synchronize do
        @items.reject! { |i| i[:key] == key.to_sym }
      end
    end

    # Modify an existing item
    def modify(key, **changes)
      @mutex.synchronize do
        item = @items.find { |i| i[:key] == key.to_sym }
        raise ArgumentError, "Navigation item not found: #{key}" unless item

        item.merge!(changes)
      end
    end

    # Add a child item to a parent
    def add_child(parent_key, child)
      child = normalize_item(child)
      validate_item!(child)

      @mutex.synchronize do
        parent = @items.find { |i| i[:key] == parent_key.to_sym }
        raise ArgumentError, "Parent navigation item not found: #{parent_key}" unless parent

        parent[:children] ||= []
        # Remove existing child with same key if present
        parent[:children].reject! { |c| c[:key] == child[:key] }
        parent[:children] << child
        parent[:children].sort_by! { |c| c[:priority] }
      end
      child
    end

    # Get all items for a specific section, sorted by priority
    def items_for_section(section)
      @mutex.synchronize do
        @items
          .select { |i| i[:section] == section.to_sym }
          .sort_by { |i| i[:priority] }
      end
    end

    # Get all items, sorted by priority
    def all
      @mutex.synchronize do
        @items.sort_by { |i| i[:priority] }
      end
    end

    # Get a specific item by key
    def find(key)
      @mutex.synchronize do
        @items.find { |i| i[:key] == key.to_sym }
      end
    end

    # Clear all items (useful for testing or reloading)
    def reset!
      @mutex.synchronize do
        @items = []
      end
    end

    private

    def normalize_item(item)
      item = item.dup
      item[:key] = item[:key]&.to_sym
      item[:section] ||= DEFAULT_SECTION
      item[:section] = item[:section].to_sym
      item[:priority] ||= DEFAULT_PRIORITY
      item[:type] ||= :button
      item[:type] = item[:type].to_sym
      item[:desktop] = true unless item.key?(:desktop)
      item[:mobile] = true unless item.key?(:mobile)
      item[:requires_auth] ||= false
      item[:requires_user] ||= false
      if item[:children]
        item[:children].map! { |c| normalize_item(c) }
        item[:children].sort_by! { |c| c[:priority] }
      end
      item
    end

    def validate_item!(item, parent_key: nil)
      context = parent_key ? " (child of #{parent_key})" : ""
      raise ArgumentError, "Navigation item must have a :key#{context}" unless item[:key]
      raise ArgumentError, "Navigation item must have a :label#{context}" unless item[:label]
      raise ArgumentError, "Navigation item must have a :key" unless item[:key]
      raise ArgumentError, "Navigation item must have a :label" unless item[:label]

      valid_types = %i[button link component partial divider raw]
      unless valid_types.include?(item[:type])
        raise ArgumentError, "Invalid navigation item type: #{item[:type]}#{context}. Valid types: #{valid_types.join(', ')}"
      end

      # Validate children recursively
      item[:children]&.each { |child| validate_item!(child, parent_key: item[:key]) }
    end
  end
end
