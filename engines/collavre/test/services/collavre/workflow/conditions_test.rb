# frozen_string_literal: true

require "test_helper"

module Collavre
  module Workflow
    class ConditionsTest < ActiveSupport::TestCase
      Envelope = SystemEvents::Envelope

      test "matches when conditions are empty or unsupported" do
        assert Conditions.match?({}, {})
        assert Conditions.match?({ "future_predicate" => false }, {})
      end

      test "matches an envelope source from the allowed list" do
        context = { Envelope::KEY => Envelope.root("comment_created", source: "comment_callback").to_h }

        assert Conditions.match?({ "source" => [ "cron", "comment_callback" ] }, context)
        refute Conditions.match?({ "source" => [ "cron" ] }, context)
      end

      test "does not match a source condition without an envelope" do
        refute Conditions.match?({ "source" => [ "comment_callback" ] }, {})
        refute Conditions.match?({ "source" => [ "unknown" ] }, {})
      end

      test "uses the envelope unknown sentinel when source is unspecified" do
        context = { Envelope::KEY => { "id" => "legacy-event" } }

        assert Conditions.match?({ "source" => [ "unknown" ] }, context)
        refute Conditions.match?({ "source" => [ "comment_callback" ] }, context)
      end

      test "matches whether the comment author is an agent" do
        assert Conditions.match?(
          { "author_agent" => true },
          { "comment" => { "user_id" => users(:ai_bot).id } }
        )
        assert Conditions.match?(
          { "author_agent" => false },
          { "comment" => { "user_id" => users(:one).id } }
        )
        refute Conditions.match?(
          { "author_agent" => true },
          { "comment" => { "user_id" => users(:one).id } }
        )
      end

      test "looks up the comment author once per evaluation" do
        calls = 0
        agent = users(:ai_bot)
        finder = lambda do |attributes|
          calls += 1
          agent if attributes[:id] == agent.id
        end

        User.stub(:find_by, finder) do
          assert Conditions.match?(
            { "author_agent" => true },
            { "comment" => { "user_id" => agent.id } }
          )
        end

        assert_equal 1, calls
      end

      test "a missing author does not provide identity evidence" do
        refute Conditions.match?({ "author_agent" => true }, { "comment" => {} })
        refute Conditions.match?({ "author_agent" => false }, { "comment" => {} })
      end

      test "matches any body fragment case insensitively" do
        context = { "comment" => { "content" => "Ready to DEPLOY today" } }

        assert Conditions.match?({ "body_contains" => [ "ship", "deploy" ] }, context)
        refute Conditions.match?({ "body_contains" => [ "rollback" ] }, context)
        refute Conditions.match?({ "body_contains" => [ "deploy" ] }, { "comment" => {} })
      end

      test "evaluates wrapped and complete Liquid expressions" do
        context = { "comment" => { "content" => "deploy now" } }

        assert Conditions.match?({ "liquid" => "comment.content contains 'deploy'" }, context)
        assert Conditions.match?({ "liquid" => "{% if comment.content == 'deploy now' %}true{% endif %}" }, context)
        refute Conditions.match?({ "liquid" => "comment.content contains 'rollback'" }, context)
      end

      test "removes caller-provided agent variables without mutating context" do
        contexts = [
          { "agent" => { "id" => 1 }, "comment" => { "content" => "deploy" } },
          { agent: { id: 1 }, "comment" => { "content" => "deploy" } }
        ]

        contexts.each do |context|
          original = context.deep_dup

          refute Conditions.match?({ "liquid" => "agent.id == 1" }, context)
          assert_equal original, context
        end
      end

      test "returns false when Liquid evaluation raises" do
        refute Conditions.match?({ "liquid" => "{% if" }, {})
      end

      test "Liquid errors log only the exception class without customer text" do
        lines = []
        Rails.logger.stub(:error, ->(line) { lines << line }) do
          refute Conditions.match?({ "liquid" => "{% confidential_customer_tag %}" }, {})
          Liquid::Template.stub(:parse, ->(*) { raise Liquid::SyntaxError, "private text\nforged log" }) do
            refute Conditions.match?({ "liquid" => "true" }, {})
          end
        end

        assert_equal 2, lines.size
        lines.each do |line|
          assert_equal "[Workflow::Conditions] Liquid error=Liquid::SyntaxError rule_id=nil", line
        end
      end

      test "evaluates Liquid last and short circuits on an earlier mismatch" do
        parser = ->(*) { flunk "Liquid should not be parsed" }

        Liquid::Template.stub(:parse, parser) do
          refute Conditions.match?(
            { "source" => [ "cron" ], "liquid" => "true" },
            {}
          )
        end
      end

      test "requires every specified predicate to match" do
        context = {
          Envelope::KEY => Envelope.root("comment_created", source: "cron").to_h,
          "comment" => { "user_id" => users(:ai_bot).id, "content" => "Deploy now" }
        }
        conditions = {
          "source" => [ "cron" ],
          "author_agent" => true,
          "body_contains" => [ "deploy" ],
          "liquid" => "comment.content == 'Deploy now'"
        }

        assert Conditions.match?(conditions, context)
      end
    end
  end
end
