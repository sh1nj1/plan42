require "closure_tree"

ActiveSupport.on_load(:active_record) do
  next unless respond_to?(:acts_as_tree)
  next if respond_to?(:has_closure_tree)

  class << self
    alias_method :has_closure_tree, :acts_as_tree
  end

  unless respond_to?(:attr_accessible)
    def self.attr_accessible(*)
      # no-op shim for closure_tree compatibility
    end
  end
end
