require "test_helper"

module Collavre
  class PublicCreativesHelperTest < ActionView::TestCase
    include Collavre::PublicCreativesHelper

    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "<p>Plan</p>")
      perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: nil, permission: :read) }
    end

    test "the title separates adjacent blocks and is capped" do
      @creative.update!(description: "<p>Plan</p><p>Alpha</p>")
      assert_equal "Plan Alpha", public_creative_title(@creative)

      @creative.update!(description: "<p>#{'x' * 100}</p>")
      assert_equal PublicCreativesHelper::PUBLIC_TITLE_MAX_LENGTH, public_creative_title(@creative).length
    end

    test "the description reads the public children in order, skipping hidden and archived ones" do
      Creative.create!(user: @owner, parent: @creative, description: "<ul><li>One</li><li>Two</li></ul>")
      hidden = Creative.create!(user: @owner, parent: @creative, description: "<p>Secret</p>")
      perform_enqueued_jobs { CreativeShare.create!(creative: hidden, user: nil, permission: :no_access) }
      Creative.create!(user: @owner, parent: @creative, description: "<p>Old</p>", archived_at: Time.current)
      Creative.create!(user: @owner, parent: @creative, description: "Line<br>break")

      assert_equal "One Two Line break", public_creative_description(@creative)
    end

    test "a linked child contributes its origin's text" do
      origin = Creative.create!(user: @owner, description: "<p>Shared section</p>")
      perform_enqueued_jobs { CreativeShare.create!(creative: origin, user: nil, permission: :read) }
      Creative.create!(user: @owner, parent: @creative, origin: origin)

      assert_equal "Shared section", public_creative_description(@creative)
    end

    test "a linked child hidden at its placement is skipped even when its origin is public" do
      origin = Creative.create!(user: @owner, description: "<p>Shared section</p>")
      perform_enqueued_jobs { CreativeShare.create!(creative: origin, user: nil, permission: :read) }
      link = Creative.create!(user: @owner, parent: @creative, origin: origin)
      perform_enqueued_jobs { CreativeShare.create!(creative: link, user: nil, permission: :no_access) }

      assert_equal "Plan", public_creative_description(@creative)
    end

    test "the description scans past more denied children than it reads" do
      PublicCreativesHelper::PUBLIC_DESCRIPTION_CHILD_LIMIT.times do |i|
        hidden = Creative.create!(user: @owner, parent: @creative, description: "<p>Secret #{i}</p>")
        perform_enqueued_jobs { CreativeShare.create!(creative: hidden, user: nil, permission: :no_access) }
      end
      Creative.create!(user: @owner, parent: @creative, description: "<p>Visible</p>")

      assert_equal "Visible", public_creative_description(@creative)
    end

    test "the description reads at most the child limit of public children" do
      (PublicCreativesHelper::PUBLIC_DESCRIPTION_CHILD_LIMIT + 1).times do |i|
        Creative.create!(user: @owner, parent: @creative, description: "<p>c#{i}</p>")
      end

      text = public_creative_description(@creative)
      assert_includes text, "c19"
      assert_not_includes text, "c20"
    end

    test "the description falls back to the creative's own text and is capped" do
      assert_equal "Plan", public_creative_description(@creative)

      Creative.create!(user: @owner, parent: @creative, description: "<p>#{'y' * 300}</p>")
      assert_equal PublicCreativesHelper::PUBLIC_DESCRIPTION_MAX_LENGTH, public_creative_description(@creative).length
    end
  end
end
