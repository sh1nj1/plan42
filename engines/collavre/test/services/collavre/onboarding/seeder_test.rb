# frozen_string_literal: true

require "test_helper"

module Collavre
  module Onboarding
    class SeederTest < ActiveSupport::TestCase
      test "creates one root and two practice children once" do
        user = User.create!(name: "New learner", email: "learner@example.com", password: "password")

        session = Seeder.new(user: user).call

        assert_equal "first_steps", session.data["scenario_key"]
        assert_equal 2, session.root.children.count
        assert_equal "progress", session.data["current_step"]
        assert_equal "completed", session.data.dig("steps", "tree_node", "status")
        assert user.reload.onboarding_seeded_at?
        assert_equal session.root, Seeder.new(user: user).call.root
      end

      test "starts a legacy guide at the first task without requiring a UI action" do
        user = User.create!(name: "Legacy learner", email: "legacy-learner@example.com", password: "password")
        session = Seeder.new(user: user).call
        session.update!(current_step: "tree_node", steps: {})

        resumed_session = Seeder.new(user: user).call

        assert_equal "progress", resumed_session.data["current_step"]
        assert_equal "completed", resumed_session.data.dig("steps", "tree_node", "status")
      end

      test "does not treat legacy custom onboarding metadata as a seeded session" do
        user = User.create!(name: "Legacy metadata learner", email: "legacy-metadata-learner@example.com", password: "password")
        unmarked = Creative.create!(
          user: user,
          description: "Existing workspace item",
          data: { "onboarding" => { "session_id" => SecureRandom.uuid, "scenario_key" => "first_steps" } }
        )
        unregistered = Creative.create!(
          user: user,
          description: "Other workspace item",
          data: { "onboarding" => { "seeded" => true, "session_id" => SecureRandom.uuid, "scenario_key" => "custom" } }
        )
        marked = Creative.create!(
          user: user,
          description: "Marked workspace item",
          data: { "onboarding" => { "seeded" => true, "session_id" => SecureRandom.uuid, "scenario_key" => "first_steps" } }
        )

        assert_nil Session.for_user(user)
        assert_nil Seeder.new(user: user).call
        assert Creative.exists?(unmarked.id)
        assert Creative.exists?(unregistered.id)
        assert Creative.exists?(marked.id)
      end

      test "shares the practice tree with an available AI agent" do
        user = User.create!(name: "Learner with agent", email: "learner-with-agent@example.com", password: "password")
        agent = User.create!(
          name: "Helpful agent", email: "helpful-agent@example.com", password: "password",
          llm_vendor: "openai", searchable: true
        )

        session = Seeder.new(user: user).call

        assert_equal "feedback", CreativeShare.find_by!(creative: session.root, user: agent).permission
        assert session.practice_creatives.all? { |creative| creative.has_permission?(agent, :feedback) }
        assert_equal true, session.data["agent_mention_enabled"]
        assert_equal agent.id, session.data["agent_mention_agent_id"]
      end

      test "selects an AI agent whose canonical mention resolves unambiguously" do
        user = User.create!(name: "Mention learner", email: "mention-learner@example.com", password: "password")
        duplicate_one = User.create!(name: "Duplicate helper", email: "duplicate-helper@example.com", password: "password",
                                     llm_vendor: "openai", searchable: true)
        duplicate_two = User.create!(name: "Duplicate helper", email: "duplicate-helper-two@example.com", password: "password",
                                     llm_vendor: "openai", searchable: true)
        colon_agent = User.create!(name: "Colon: helper", email: "colon-helper@example.com", password: "password",
                                   llm_vendor: "openai", searchable: true)
        agent = User.create!(name: "Unique helper", email: "unique-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)

        candidates = User.where(id: [ duplicate_one.id, duplicate_two.id, colon_agent.id, agent.id ]).order(:id)
        session = User.stub(:accessible_ai_agents_for, candidates) { Seeder.new(user: user).call }

        assert_equal agent.id, session.data["agent_mention_agent_id"]
        assert_equal agent, MentionParser.resolve_user("@#{agent.name}: hello")
      end

      test "skips an agent whose whitespace name cannot resolve from its canonical mention" do
        user = User.create!(name: "Whitespace mention learner", email: "whitespace-mention-learner@example.com", password: "password")
        whitespace_agent = User.create!(name: " Helper", email: "whitespace-helper@example.com", password: "password",
                                        llm_vendor: "openai", searchable: true)
        agent = User.create!(name: "Resolvable helper", email: "resolvable-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)

        candidates = User.where(id: [ whitespace_agent.id, agent.id ]).order(:id)
        session = User.stub(:accessible_ai_agents_for, candidates) { Seeder.new(user: user).call }

        assert_equal agent.id, session.data["agent_mention_agent_id"]
        assert_nil MentionParser.resolve_user("@#{whitespace_agent.name}:")
      end

      test "omits the agent mention step when no agent is available" do
        user = User.create!(name: "Core-only learner", email: "core-only-learner@example.com", password: "password")

        User.stub(:accessible_ai_agents_for, User.none) do
          session = Seeder.new(user: user).call

          assert_equal false, session.data["agent_mention_enabled"]
          refute_includes session.scenario.steps.map(&:key), :mention
        end
      end

      test "omits the agent mention step when the seeded agent loses feedback access" do
        user = User.create!(name: "Agent access learner", email: "agent-access-learner@example.com", password: "password")
        agent = User.create!(
          name: "Temporary helper", email: "temporary-helper@example.com", password: "password",
          llm_vendor: "openai", searchable: true
        )
        session = Seeder.new(user: user).call

        CreativeShare.find_by!(creative: session.root, user: agent).destroy!

        refute_includes session.scenario.steps.map(&:key), :mention
        session.update!(current_step: "mention")
        assert_nil session.current_step
        assert_equal "complete", session.data["current_step"]
      end

      test "defers cleanup for a damaged session while its agent turn is active" do
        previous_adapter = ActiveJob::Base.queue_adapter
        ActiveJob::Base.queue_adapter = :test
        user = User.create!(name: "Damaged session learner", email: "damaged-session-learner@example.com", password: "password")
        agent = User.create!(name: "Damaged session helper", email: "damaged-session-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        comment = Comment.create!(creative: session.practice_creatives.second, user: user, content: "@Damaged session helper: Please help")
        Task.create!(name: "Response", status: "running", trigger_event_name: "comment_created",
                     trigger_event_payload: { "comment" => { "id" => comment.id } }, agent: agent,
                     creative: session.practice_creatives.second)
        session.practice_creatives.first.archive!

        assert_enqueued_with(job: OnboardingCleanupJob, args: [ user.id, session.session_id ]) do
          assert_nil Seeder.new(user: user).call
        end

        assert Creative.exists?(session.root.id)
        assert Comment.exists?(comment.id)
        assert user.reload.onboarding_completed_at?
      ensure
        ActiveJob::Base.queue_adapter = previous_adapter
      end

      test "removes the mention step when the seeded helper can no longer be mentioned" do
        user = User.create!(name: "Renamed helper learner", email: "renamed-helper-learner@example.com", password: "password")
        agent = User.create!(name: "Temporary helper", email: "temporary-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        agent.update!(name: "Temporary: helper")
        session.update!(current_step: "mention")

        refute_includes session.scenario.steps.map(&:key), :mention
        assert_nil session.current_step
        assert_equal "complete", session.data["current_step"]
      end

      test "removes the mention step when the seeded helper name becomes non-unique" do
        user = User.create!(name: "Duplicate helper learner", email: "duplicate-helper-learner@example.com", password: "password")
        agent = User.create!(name: "Shared helper", email: "shared-helper@example.com", password: "password",
                             llm_vendor: "openai", searchable: true)
        session = Seeder.new(user: user).call
        User.create!(name: agent.name, email: "second-shared-helper@example.com", password: "password")
        session.update!(current_step: "mention")

        refute_includes session.scenario.steps.map(&:key), :mention
        assert_nil session.current_step
        assert_equal "complete", session.data["current_step"]
      end

      test "resolves a practice creative to its scenario root" do
        user = User.create!(name: "Practice learner", email: "practice-learner@example.com", password: "password")
        seeded_session = Seeder.new(user: user).call

        session = Session.for_creative(seeded_session.practice_creatives.first)

        assert_equal seeded_session.root, session.root
        assert_equal :first_steps, session.scenario.key
      end

      test "builds step navigation inside a mounted engine" do
        user = User.create!(name: "Mounted learner", email: "mounted-onboarding@example.com", password: "password")
        User.create!(
          name: "Mounted helper", email: "mounted-helper@example.com", password: "password",
          llm_vendor: "openai", searchable: true
        )
        session = Seeder.new(user: user).call
        steps = session.scenario.steps.index_by(&:key)

        assert_equal "/collavre/creatives?id=#{session.root.id}&open_comments=true",
                     session.navigation_path(steps.fetch(:progress), script_name: "/collavre")
        assert_equal "/collavre/creatives?id=#{session.root.id}&open_comments=true",
                     session.navigation_path(steps.fetch(:editor), script_name: "/collavre")
        assert_equal "/collavre/creatives?id=#{session.practice_creatives.second.id}&open_comments=true",
                     session.navigation_path(steps.fetch(:comment), script_name: "/collavre")
        assert_equal "/collavre/creatives?id=#{session.practice_creatives.second.id}&open_comments=true",
                     session.navigation_path(steps.fetch(:mention), script_name: "/collavre")
      end

      test "does not add onboarding to an existing workspace" do
        user = users(:one)

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
      end

      test "force seeds onboarding alongside an existing workspace" do
        user = users(:one)

        session = Seeder.new(user: user, force: true).call

        assert_equal "first_steps", session.data["scenario_key"]
        assert user.reload.onboarding_seeded_at?
      end

      test "marks a deleted onboarding session complete without reseeding it" do
        user = User.create!(name: "Deleted onboarding", email: "deleted-onboarding@example.com", password: "password")
        session = Seeder.new(user: user).call
        practice_ids = session.practice_creatives.map(&:id)
        Creatives::DestroyService.new(creative: session.root, user: user).call

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_nil Session.for_user(user)
        assert_empty user.creatives.where(id: practice_ids)
      end

      test "cleans up and completes a session with a deleted practice creative" do
        user = User.create!(name: "Damaged onboarding", email: "damaged-onboarding@example.com", password: "password")
        session = Seeder.new(user: user).call
        remaining_practice = session.practice_creatives.second

        Creatives::DestroyService.new(creative: session.practice_creatives.first, user: user).call

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_nil Session.for_user(user)
        refute Creative.exists?(session.root.id)
        refute Creative.exists?(remaining_practice.id)
      end

      test "cleans up and completes a session with an archived onboarding root" do
        user = User.create!(name: "Archived onboarding root", email: "archived-onboarding-root@example.com", password: "password")
        session = Seeder.new(user: user).call
        creative_ids = [ session.root.id, *session.practice_creative_ids ]
        session.root.archive!

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_empty user.creatives.where(id: creative_ids)
      end

      test "cleans up and completes a session with an archived practice creative" do
        user = User.create!(name: "Archived onboarding practice", email: "archived-onboarding-practice@example.com", password: "password")
        session = Seeder.new(user: user).call
        creative_ids = [ session.root.id, *session.practice_creative_ids ]
        session.practice_creatives.first.archive!

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_empty user.creatives.where(id: creative_ids)
      end

      test "cleans up and completes a session with a practice creative moved outside its root" do
        user = User.create!(name: "Moved onboarding practice", email: "moved-onboarding-practice@example.com", password: "password")
        session = Seeder.new(user: user).call
        creative_ids = [ session.root.id, *session.practice_creative_ids ]
        outside_root = Creative.create!(user: user, description: "Outside onboarding")
        session.practice_creatives.second.update!(parent: outside_root)

        assert_nil Seeder.new(user: user).call
        assert user.reload.onboarding_completed_at?
        assert_empty user.creatives.where(id: creative_ids)
      end
    end
  end
end
