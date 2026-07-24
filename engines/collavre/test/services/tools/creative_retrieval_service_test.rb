require "test_helper"

module Tools
  class CreativeRetrievalServiceTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)
      @other_user = users(:two)

      perform_enqueued_jobs do
        @parent = Creative.create!(user: @user, description: "Parent Creative", progress: 0.5)
        @child = Creative.create!(user: @user, parent: @parent, description: "Child Creative", progress: 1.0)
        @child2 = Creative.create!(user: @user, parent: @parent, description: "Another Child", progress: 0.0)

        # Setup another user who has permission on the parent
        CreativeShare.create!(user: @other_user, creative: @parent, permission: :read)
      end
    end

    # --- A. Direct model access (no controller mocking) ---

    test "retrieves root creatives when no id or query given" do
      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call

        assert_kind_of String, result
        assert_includes result, "[#{@parent.id}] Parent Creative"
      end
    end

    test "retrieves children when user has permission on parent (markdown)" do
      Current.set(user: @other_user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(id: @parent.id, level: 2)

        assert_kind_of String, result
        assert_includes result, "<!-- format:"
        assert_includes result, "[#{@parent.id}] Parent Creative"
        assert_includes result, "[#{@child.id}] Child Creative"
      end
    end

    test "retrieves children in json format" do
      Current.set(user: @other_user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(id: @parent.id, level: 2, format: "json")

        assert_kind_of Array, result
        parent_result = result.first
        assert_equal @parent.id, parent_result[:id]
        assert_equal "Parent Creative", parent_result[:description]
        assert_includes parent_result.keys, :tags
        assert_includes parent_result.keys, :created_at
        assert_includes parent_result.keys, :updated_at
        assert_not_empty parent_result[:children]
      end
    end

    test "search by query text returns flat list" do
      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(query: "Child")

        assert_kind_of Array, result
        descriptions = result.map { |r| r[:description] }
        assert_includes descriptions, "Child Creative"
        assert_includes descriptions, "Another Child"
        # Each item should have id, description, progress
        result.each do |item|
          assert_includes item.keys, :id
          assert_includes item.keys, :description
          assert_includes item.keys, :progress
        end
      end
    end

    test "returns empty for inaccessible creative" do
      other_parent = nil
      perform_enqueued_jobs do
        other_parent = Creative.create!(user: @other_user, description: "Private Creative")
      end

      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(id: other_parent.id)

        # Should return just the header, no content
        assert_kind_of String, result
        refute_includes result, "Private Creative"
      end
    end

    # --- B. Markdown format ---

    test "markdown format includes header and compact tree" do
      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(id: @parent.id, level: 3)

        lines = result.strip.split("\n")
        assert_match(/<!-- format:/, lines.first)
        assert_match(/\- \[\d+\].*\(\d+%\)/, lines[1])
      end
    end

    test "markdown tree respects level depth" do
      grandchild = nil
      perform_enqueued_jobs do
        grandchild = Creative.create!(user: @user, parent: @child, description: "Grandchild")
      end

      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new

        # level 2: parent + children only
        result = service.call(id: @parent.id, level: 2)
        refute_includes result, "Grandchild"

        # level 3: includes grandchild
        result = service.call(id: @parent.id, level: 3)
        assert_includes result, "Grandchild"
      end
    end

    # --- C. Filters ---

    test "filter by progress range" do
      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new

        # Only completed items
        result = service.call(query: "Child", progress_min: 1.0)
        descriptions = result.map { |r| r[:description] }
        assert_includes descriptions, "Child Creative"
        refute_includes descriptions, "Another Child"

        # Only incomplete items
        result = service.call(query: "Child", progress_max: 0.5)
        descriptions = result.map { |r| r[:description] }
        refute_includes descriptions, "Child Creative"
        assert_includes descriptions, "Another Child"
      end
    end

    test "filter by updated_since" do
      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new

        # All should be recent
        result = service.call(query: "Child", updated_since: 1.hour.ago.iso8601)
        descriptions = result.map { |r| r[:description] }
        assert_includes descriptions, "Child Creative"

        # None should match far future
        result = service.call(query: "Child", updated_since: 1.day.from_now.iso8601)
        descriptions = result.map { |r| r[:description] }
        refute_includes descriptions, "Child Creative"
      end
    end

    test "filter by tags" do
      perform_enqueued_jobs do
        label = Label.create!(creative_id: @parent.id, value: "important", owner_id: @user.id)
        Tag.create!(creative_id: @child.id, label: label)
      end

      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new
        result = service.call(query: "Child", tags: "important")
        descriptions = result.map { |r| r[:description] }
        assert_includes descriptions, "Child Creative"
      end
    end

    test "include_comments adds comment content" do
      Comment.create!(creative: @child, user: @user, content: "This is a test comment")

      Current.set(user: @user) do
        service = Tools::CreativeRetrievalService.new

        # Markdown with comments
        result = service.call(id: @parent.id, level: 2, include_comments: true)
        assert_includes result, "test comment"

        # JSON with comments
        result = service.call(id: @parent.id, level: 2, include_comments: true, format: "json")
        child_node = result.first[:children].find { |c| c[:id] == @child.id }
        assert_not_empty child_node[:recent_comments]
      end
    end

    test "raises error without Current.user" do
      Current.set(user: nil) do
        service = Tools::CreativeRetrievalService.new
        error = assert_raises(RuntimeError) do
          service.call
        end
        assert_match(/Current.user is required/, error.message)
      end
    end
  end
end
