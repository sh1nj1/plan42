require "closure_tree"

module ClosureTree
  module ActsAsTree
    def has_closure_tree(options = {})
      return super if defined?(super)

      acts_as_tree(options)
    end
  end
end
