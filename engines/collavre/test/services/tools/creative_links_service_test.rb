require "test_helper"

module Collavre
  module Tools
    class CreativeLinksServiceTest < ActiveSupport::TestCase
      setup do
        @user = users(:one)
        Current.user = @user
        @parent = Creative.create!(user: @user, description: "Destination")
        @a = Creative.create!(user: @user, description: "Source A")
        @b = Creative.create!(user: @user, description: "Source B")
        @linker = CreativeLinkService.new
        @unlinker = CreativeUnlinkService.new
      end

      teardown { Current.reset }

      test "links in order and reuses existing links without modifying origins" do
        result = link(@a, @b)
        assert result[:success], result.inspect
        assert_equal [ @a.id, @b.id ], @parent.children.order(:sequence).pluck(:origin_id)
        assert_equal result[:links], link(@a, @b)[:links]
        assert_nil @a.reload.parent_id
        assert_equal 2, @parent.children.count
        assert_equal [ 0, 1 ], @parent.children.order(:sequence).pluck(:sequence)
      end

      test "existing links retain their positions while new links are appended" do
        first = link(@b)
        result = link(@a, @b)
        assert result[:success]
        assert_equal first[:links].first[:id], result[:links].last[:id]
        assert_equal [ @b.id, @a.id ], @parent.children.order(:sequence).pluck(:origin_id)
      end

      test "links resolve source and destination shells to origins" do
        source = Creative.create!(user: @user, origin: @a)
        parent = Creative.create!(user: @user, origin: @parent)
        result = @linker.call(parent_id: parent.id, creative_ids: [ source.id, @b.id ])
        assert result[:success], result.inspect
        assert_equal @parent.id, result[:parent_id]
        assert_equal [ @a.id, @b.id ], @parent.children.order(:sequence).pluck(:origin_id)
        assert_equal [ 0, 1 ], @parent.children.order(:sequence).pluck(:sequence)
      end

      test "rejects missing invalid and duplicate ids" do
        [ [], [ 0 ], [ -1 ], [ "bad" ], [ @a.id, @a.id ], "1,2", nil ].each do |ids|
          assert @linker.call(parent_id: @parent.id, creative_ids: ids)[:error]
          assert @unlinker.call(linked_creative_ids: ids)[:error]
        end
        assert @linker.call(parent_id: 0, creative_ids: [ @a.id ])[:error]
        assert @linker.call(parent_id: @parent.id, creative_ids: [ 0x7fffffff ])[:error]
        assert @unlinker.call(linked_creative_ids: [ 0x7fffffff ])[:error]
      end

      test "rejects cycles and rolls back the entire list" do
        before = Creative.count
        result = link(@a, @parent)
        assert result[:error]
        assert_equal before, Creative.count
        child = Creative.create!(user: @user, parent: @a, description: "Child")
        assert @linker.call(parent_id: child.id, creative_ids: [ @a.id ])[:error]
      end

      test "requires read on sources and write on destination" do
        other = users(:two)
        source = Creative.create!(user: other, description: "Other")
        assert link(@a, source)[:error]
        assert_empty @parent.children
        Current.set(user: other) { assert link(@a)[:error] }
        CreativeShare.create!(creative: source, user: @user, permission: :read)
        assert link(source)[:success]
      end

      test "does not reuse sources or parents placed in another user's private tree" do
        other = users(:two)
        hidden = Creative.create!(user: other, origin: @a)
        assert link(hidden)[:error]
        hidden_parent = Creative.create!(user: other, origin: @parent)
        assert @linker.call(parent_id: hidden_parent.id, creative_ids: [ @a.id ])[:error]
      end

      test "unlink preserves origins children shares other and downstream links" do
        child = Creative.create!(user: @user, parent: @a, description: "Child")
        share = CreativeShare.create!(creative: @a, user: users(:two), permission: :read)
        result = link(@a, @b)
        shell = Creative.find(result[:links].first[:id])
        downstream = Creative.create!(user: @user, origin: shell)
        other = Creative.create!(user: @user, origin: @a)
        assert @unlinker.call(linked_creative_ids: result[:links].map { |l| l[:id] })[:success]
        assert_not Creative.exists?(shell.id)
        assert Creative.exists?(@a.id)
        assert Creative.exists?(child.id)
        assert CreativeShare.exists?(share.id)
        assert Creative.exists?(other.id)
        assert_equal @a.id, downstream.reload.origin_id
      end

      test "unlink rejects ordinary creatives and unauthorized shells atomically" do
        shell = Creative.find(link(@a)[:links].first[:id])
        assert @unlinker.call(linked_creative_ids: [ shell.id, @a.id ])[:error]
        assert Creative.exists?(shell.id)
        foreign = Creative.create!(user: users(:two), origin: @b)
        # Admin access on an origin is the existing model's removal rule.
        Current.set(user: users(:two)) do
          assert @unlinker.call(linked_creative_ids: [ foreign.id, shell.id ])[:error]
        end
        assert Creative.exists?(foreign.id)
      end

      test "shell owner can unlink a read-only origin" do
        source = Creative.create!(user: users(:two), description: "Other")
        CreativeShare.create!(creative: source, user: @user, permission: :read)
        shell = Creative.create!(user: @user, origin: source)
        assert @unlinker.call(linked_creative_ids: [ shell.id ])[:success]
        assert Creative.exists?(source.id)
      end

      test "link review captures origin and applies a linked shell" do
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { link(@a, @b) }
        assert result[:pending_review], result.inspect
        assert_empty @parent.children
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal [ @a.id, @b.id ], draft.creative_changes.where(operation: "create").order(:position).map { |c| c.after["origin_id"] }
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :applied, applied.status
        assert_equal [ @a.id, @b.id ], @parent.children.order(:sequence).pluck(:origin_id)
      end

      test "link approval rechecks source read permission and cycles" do
        source = Creative.create!(user: users(:two), description: "Other")
        grant = CreativeShare.create!(creative: source, user: @user, permission: :read)
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { link(source) }
        grant.update!(permission: :no_access)
        draft = CreativeChangeSet.find(result[:change_set_id])
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :skipped, applied.status
        assert_empty @parent.children
        grant.update!(permission: :read)
        @parent.update!(parent: source)
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :skipped, applied.status
        assert_empty @parent.children
      end

      test "unlink review preserves the shell until approval and then removes only the shell" do
        shell = Creative.find(link(@a)[:links].first[:id])
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { @unlinker.call(linked_creative_ids: [ shell.id ]) }
        assert result[:pending_review], result.inspect
        assert Creative.exists?(shell.id)
        draft = CreativeChangeSet.find(result[:change_set_id])
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :applied, applied.status
        assert_not Creative.exists?(shell.id)
        assert Creative.exists?(@a.id)
        assert_equal :not_revertible, Creatives::ChangeSetApplyService.new(source: draft, user: @user).call.status
      end

      test "unlink approval rechecks removal permissions" do
        shell = Creative.find(link(@a)[:links].first[:id])
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { @unlinker.call(linked_creative_ids: [ shell.id ]) }
        draft = CreativeChangeSet.find(result[:change_set_id])
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: users(:two), mode: :draft).call
        assert_equal :skipped, applied.status
        assert Creative.exists?(shell.id)
      end

      test "localizes failures and requires a user" do
        I18n.with_locale(:ko) do
          assert_match "변경된 내용은 없습니다", link(@parent)[:error]
        end
        Current.user = nil
        assert_raises(RuntimeError) { link(@a) }
        assert_raises(RuntimeError) { @unlinker.call(linked_creative_ids: [ @a.id ]) }
      end

      test "meta_tool discovers describes and executes link and unlink" do
        meta = ::Tools::MetaToolService.new
        names = meta.call(action: "search", query: "creative_link")[:tools].map { |tool| tool[:name] }
        assert_includes names, "creative_link_service"
        assert_equal "creative_unlink_service", meta.call(action: "get", tool_name: "creative_unlink_service").dig(:tool, :name)
        linked = meta.call(action: "run", tool_name: "creative_link_service", arguments: { parent_id: @parent.id, creative_ids: [ @a.id ] })
        assert linked.dig(:result, :success), linked.inspect
        ids = linked.dig(:result, :links).map { |link| link[:id] }
        removed = meta.call(action: "run", tool_name: "creative_unlink_service", arguments: { linked_creative_ids: ids })
        assert removed.dig(:result, :success), removed.inspect
      end

      test "link and unlink update parent progress with review replay" do
        @a.update!(progress: 1.0)
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { link(@a) }
        assert_equal 0.0, @parent.reload.progress
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal :applied, Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call.status
        assert_equal 1.0, @parent.reload.progress
        shell = @parent.children.sole
        result = Current.set(mcp_request: true) { @unlinker.call(linked_creative_ids: [ shell.id ]) }
        assert result[:pending_review], result.inspect
        assert_equal 1.0, @parent.reload.progress
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal :applied, Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call.status
        assert_equal 0.0, @parent.reload.progress
        assert_equal 1.0, @a.reload.progress
      end

      test "ancestor progress review policy is captured even with an auto parent" do
        root = Creative.create!(user: @user, description: "Review", data: { "ai_write_policy" => "review" })
        @parent.update!(parent: root, data: { "ai_write_policy" => "auto" })
        @a.update!(progress: 1.0)
        result = Current.set(mcp_request: true) { link(@a) }
        assert result[:pending_review], result.inspect
        assert_empty @parent.children
        assert_equal 0.0, root.reload.progress
      end

      test "Kollavy scoped calls cannot link or unlink outside their boundary" do
        shell = Creative.find(link(@a)[:links].first[:id])
        agent = Kollavy.seed!
        task = Task.create!(agent: agent, creative: @b, name: "Scoped links")
        Current.set(user: agent, agent_turn: { user: @user, task: task }) do
          assert link(@a)[:error]
          assert @unlinker.call(linked_creative_ids: [ shell.id ])[:error]
        end
        assert Creative.exists?(shell.id)
      end

      test "shell owner can approve unlink after origin access is revoked" do
        source = Creative.create!(user: users(:two), description: "Private source")
        grant = CreativeShare.create!(creative: source, user: @user, permission: :read)
        shell = Creative.find(link(source)[:links].first[:id])
        grant.update!(permission: :no_access)
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { @unlinker.call(linked_creative_ids: [ shell.id ]) }
        assert result[:pending_review], result.inspect
        draft = CreativeChangeSet.find(result[:change_set_id])
        assert_equal 1, Creatives::ChangeSetDiff.new(draft, user: @user).change_count
        assert_equal 0, Creatives::ChangeSetDiff.new(draft, user: users(:two)).change_count
        applied = Creatives::ChangeSetApplyService.new(source: draft, user: @user, mode: :draft).call
        assert_equal :applied, applied.status
        assert_not Creative.exists?(shell.id)
        assert Creative.exists?(source.id)
      end

      test "review diff identifies link origins without exposing their content" do
        @parent.update!(data: { "ai_write_policy" => "review" })
        result = Current.set(mcp_request: true) { link(@a) }
        draft = CreativeChangeSet.find(result[:change_set_id])
        diff = Creatives::ChangeSetDiff.new(draft, user: @user)
        assert_includes diff.groups.sole[:after], "Linked Creative [#{@a.id}]"
        assert_not_includes diff.groups.sole[:after], "Source A"
      end

      test "a late link failure rolls back writes and does not poison the next call" do
        Current.change_set = nil
        Current.creative_history_context = nil
        real = Creatives::Reorderer.new(user: @user)
        count = 0
        failing = Object.new
        failing.define_singleton_method(:validate_link!) { |**args| real.validate_link!(**args) }
        failing.define_singleton_method(:link_drop) do |**args|
          count += 1
          raise Creatives::Reorderer::Error if count == 2
          real.link_drop(**args)
        end
        Creatives::Reorderer.stub(:new, ->(**) { failing }) { assert link(@a, @b)[:error] }
        assert_empty @parent.children
        assert link(@a, @b)[:success]
      end

      test "a late unlink failure rolls back all removals and preserves history context" do
        shells = link(@a, @b)[:links].map { |l| Creative.find(l[:id]) }
        Current.change_set = nil
        Current.creative_history_context = nil
        failing = shells.last
        failing.define_singleton_method(:destroy!) { raise ActiveRecord::RecordNotDestroyed }
        @unlinker.stub(:unlink_all, ->(_ids) { shells.first.destroy!; failing.destroy! }) do
          assert @unlinker.call(linked_creative_ids: shells.map(&:id))[:error]
        end
        assert shells.all? { |shell| Creative.exists?(shell.id) }
        assert @unlinker.call(linked_creative_ids: shells.map(&:id))[:success]
      end

      private

      def link(*sources)
        @linker.call(parent_id: @parent.id, creative_ids: sources.map(&:id))
      end
    end
  end
end
