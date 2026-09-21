# frozen_string_literal: true

require "test_helper"

module Collavre
  class CreativeTreeInvalidationJobTest < ActiveJob::TestCase
    test "ignores an empty creative list" do
      Turbo::StreamsChannel.stub(:broadcast_action_to, ->(*) { flunk "empty invalidations must not broadcast" }) do
        CreativeTreeInvalidationJob.perform_now([])
      end
      assert true
    end

    test "broadcasts a generic invalidation to every readable user" do
      owner = users(:one)
      reader = users(:two)
      creative = Creative.create!(description: "Shared", user: owner)
      CreativeSharesCache.create!(creative: creative, user: reader, permission: :read)
      broadcasts = []

      Turbo::StreamsChannel.stub(:broadcast_action_to, ->(*stream, **options) { broadcasts << [ stream, options ] }) do
        CreativeTreeInvalidationJob.perform_now([ creative.id ])
      end

      assert_equal [ owner.id, reader.id ].sort, broadcasts.map { |stream, _options| stream.first.first.id }.sort
      assert broadcasts.all? { |_stream, options| options[:action] == :invalidate_creative_tree }
      assert broadcasts.all? { |_stream, options| options[:target] == "creatives" }
    end

    test "does not broadcast to an explicitly denied user of a public creative" do
      owner = users(:one)
      denied = users(:two)
      creative = Creative.create!(description: "Public", user: owner)
      CreativeSharesCache.create!(creative: creative, user: nil, permission: :read)
      CreativeSharesCache.create!(creative: creative, user: denied, permission: :no_access)
      recipients = []

      Turbo::StreamsChannel.stub(:broadcast_action_to, ->(stream, **) { recipients << stream.first.id }) do
        CreativeTreeInvalidationJob.perform_now([ creative.id ])
      end

      assert_includes recipients, owner.id
      assert_not_includes recipients, denied.id
    end
  end
end
