# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class TopicAuthorizerTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @member = users(:two)
        @creative = Collavre::Creative.create!(description: "Auth Host", user: @owner)
        @topic = @creative.topics.create!(name: "Gated", user: @owner)
      end

      def share!(permission)
        Collavre::CreativeShare.create!(creative: @creative, user: @member, permission: permission,
                                        shared_by: @owner)
      end

      test "the owner passes every level without holding an explicit share" do
        assert_nil TopicAuthorizer.authorize_read!(@topic, user: @owner)
        assert_nil TopicAuthorizer.authorize_write!(@topic, user: @owner)
        assert_nil TopicAuthorizer.authorize_admin!(@topic, user: @owner)
      end

      test "each level admits only what it should" do
        share!(:write)

        assert_nil TopicAuthorizer.authorize_read!(@topic, user: @member)
        assert_nil TopicAuthorizer.authorize_write!(@topic, user: @member)
        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicAuthorizer.authorize_admin!(@topic, user: @member)
        end
      end

      test "a user with no share is refused" do
        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicAuthorizer.authorize_read!(@topic, user: @member)
        end
      end

      test "a nil user is refused rather than treated as anonymous read" do
        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicAuthorizer.authorize_read!(@topic, user: nil)
        end
      end

      test "permission is resolved on the origin creative, where shares live" do
        share!(:read)
        link = Collavre::Creative.create!(description: "Link", user: @member, origin: @creative)
        linked_topic = Topic.new(creative: link, user: @member, name: "Linked")

        assert_nil TopicAuthorizer.authorize_read!(linked_topic, user: @member)
      end

      test "a topic with no creative is a caller error, not a permission failure" do
        assert_raises(ArgumentError) { TopicAuthorizer.authorize_read!(Topic.new, user: @owner) }
        assert_raises(ArgumentError) { TopicAuthorizer.authorize_creative!(nil, :read, user: @owner) }
      end

      test "readable? answers without raising, including for a broken topic" do
        share!(:read)

        assert TopicAuthorizer.readable?(@topic, user: @member)
        assert_not TopicAuthorizer.readable?(@topic, user: users(:three))
        assert_not TopicAuthorizer.readable?(Topic.new, user: @owner)
      end

      test "authorize_creative! gates topic creation on the creative itself" do
        share!(:read)

        assert_nil TopicAuthorizer.authorize_creative!(@creative, :read, user: @member)
        assert_raises(Collavre::Tools::PermissionDeniedError) do
          TopicAuthorizer.authorize_creative!(@creative, :write, user: @member)
        end
      end
    end
  end
end
