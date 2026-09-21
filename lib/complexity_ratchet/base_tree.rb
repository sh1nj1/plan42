# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module ComplexityRatchet
  # Materialises the merge base as a throwaway git worktree so both sides of the
  # comparison can be measured by one RuboCop process, in one run.
  #
  # `git stash`-style approaches were rejected: they mutate the checkout, and a
  # cancelled CI job would leave it mutated. A detached worktree touches nothing
  # the caller can see and is removed in an ensure block.
  class BaseTree
    # THIS branch's budget and RuboCop configuration are copied over the base
    # tree's, so the two measurements differ only by source code. Without that, a
    # PR that tightens a Max would measure the base with the looser limit, find
    # fewer over-budget entities there, and report every pre-existing entity the
    # tightening newly caught as brand-new debt.
    #
    # `.rubocop_metrics.yml` inherits from the rubocop-rails-omakase gem rather
    # than from another file in the repo, so it travels alone.
    CONFIG_FILES = [ CONFIG_PATH ].freeze

    class << self
      # Yields the path to a checkout of `merge-base(HEAD, ref)`.
      #
      # Returns nil without yielding when the merge base is HEAD itself — a push
      # to the base branch, where the branch has nothing to be measured against.
      def at_merge_base(root:, ref:)
        base = merge_base(root, ref)
        return nil if base.nil? || base == rev_parse(root, "HEAD")

        Dir.mktmpdir("complexity-base") do |scratch|
          tree = File.join(scratch, "tree")
          # core.hooksPath is neutralised because this repo installs a
          # post-checkout hook that runs project setup on a new worktree —
          # minutes of work, and a nonzero exit, for a tree that is only read.
          git!(root, "-c", "core.hooksPath=/dev/null",
               "worktree", "add", "--detach", "--quiet", tree, base)
          begin
            CONFIG_FILES.each { |name| FileUtils.cp(File.join(root, name), File.join(tree, name)) }
            yield tree, base
          ensure
            # --force because the copied config leaves the worktree dirty.
            git(root, "worktree", "remove", "--force", tree)
          end
        end
      end

      def merge_base(root, ref)
        out, _err, status = git(root, "merge-base", "HEAD", ref)
        status.success? ? out.strip : nil
      end

      private

      def rev_parse(root, ref)
        out, _err, status = git(root, "rev-parse", ref)
        status.success? ? out.strip : nil
      end

      # Git output is UTF-8 regardless of Encoding.default_external, which is
      # US-ASCII in a shell with no LANG set — and this repo's hooks print
      # emoji.
      def git(root, *args)
        out, err, status = Open3.capture3("git", *args, chdir: root)
        [ out.force_encoding(Encoding::UTF_8), err.force_encoding(Encoding::UTF_8), status ]
      end

      def git!(root, *args)
        out, err, status = git(root, *args)
        raise Error, "git #{args.join(' ')} failed: #{err.strip.empty? ? out : err}" unless status.success?

        out
      end
    end
  end
end
