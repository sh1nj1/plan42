require "test_helper"

module Tools
  class CreativeRetrievalPrivacyTest < ActiveSupport::TestCase
    setup do
      @owner, @collaborator = users(:one), users(:two)
      @inbox = Collavre::Creative.inbox_for(@owner)
      @agent = Collavre::Kollavy.seed!
      @child = Creative.create!(user: @owner, parent: @inbox, description: "Discussion")
      @task = Collavre::Task.create!(agent: @agent, creative: @inbox, name: "Retrieve comments")
      @service = Tools::CreativeRetrievalService.new
      @public = comment("public-needle", private: false)
      @authored = comment("authored-needle", user: @agent)
      @approved = comment("approved-needle", approver: @agent)
      3.times { |i| comment("hidden-needle-#{i}") }
    end

    teardown { Current.reset }

    test "Kollavy searches only public authored or assigned private comments" do
      as_agent do
        assert_empty @service.call(query: "hidden-needle")
        [ @public, @authored, @approved ].each do |comment|
          assert_includes @service.call(query: comment.content).pluck(:id), @child.id
        end
      end
    end

    %w[markdown json].each do |format|
      test "#{format} filters private comments before limiting recursive recent comments" do
        as_agent do
          result = @service.call(id: @inbox.id, level: 2, include_comments: true, format: format).to_s
          refute_includes result, "hidden-needle"
          [ @public, @authored, @approved ].each { |comment| assert_includes result, comment.content }
        end
      end
    end

    %w[markdown json].each do |format|
      test "#{format} excludes approval actions before limiting recent comments" do
        3.times do |i|
          comment("approval-secret-#{i}", user: @agent, approver: @owner, private: false, skip_create_notifications: true, action: { action: "execute_tool" }.to_json)
        end
        as_agent do
          result = @service.call(id: @inbox.id, level: 2, include_comments: true, format: format).to_s
          refute_includes result, "approval-secret"
          [ @public, @authored, @approved ].each { |comment| assert_includes result, comment.content }
        end
      end
    end

    test "creative ownership does not grant visibility into another author's private comments" do
      Current.set(user: @owner) do
        assert_empty @service.call(query: "hidden-needle")
        %w[markdown json].each do |format|
          result = @service.call(id: @child.id, include_comments: true, format: format).to_s
          refute_includes result, "hidden-needle"
          assert_includes result, @public.content
        end
      end
    end

    test "private comment author retains search and retrieval access" do
      perform_enqueued_jobs do
        CreativeShare.create!(user: @collaborator, creative: @inbox, permission: :read)
      end
      Current.set(user: @collaborator) do
        assert_equal [ @child.id ], @service.call(query: "hidden-needle").pluck(:id)
        %w[markdown json].each do |format|
          result = @service.call(id: @child.id, include_comments: true, format: format).to_s
          3.times { |i| assert_includes result, "hidden-needle-#{i}" }
        end
      end
    end

    private

    def comment(content, **attributes)
      Comment.create!({ creative: @child, user: @collaborator, content: content,
                        private: true, skip_dispatch: true }.merge(attributes))
    end

    def as_agent(&block)
      Current.set(user: @agent, agent_turn: { task: @task, user: @owner }, &block)
    end
  end
end
