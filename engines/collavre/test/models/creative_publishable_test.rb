require "test_helper"

module Collavre
  class CreativePublishableTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @creative = Creative.create!(user: @owner, description: "<p>Hello, Public World!</p>")
    end

    test "publicly_readable? follows the anonymous read permission" do
      assert_not @creative.publicly_readable?

      perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: nil, permission: :read) }

      assert @creative.reload.publicly_readable?
    end

    test "ensure_public_id! assigns a stable token once" do
      assert_nil @creative.public_id

      first = @creative.ensure_public_id!

      assert_match(/\A#{Creative::Publishable::PUBLIC_ID_FORMAT.source}\z/, first)
      assert_equal first, @creative.reload.public_id
      assert_equal first, @creative.ensure_public_id!
      assert_not @creative.changed?
    end

    test "ensure_public_id! keeps a token another request stored first" do
      Creative.where(id: @creative.id).update_all(public_id: "AAAAAAAAAA")

      assert_equal "AAAAAAAAAA", @creative.ensure_public_id!
    end

    test "ensure_public_id! retries when a generated token collides" do
      other = Creative.create!(user: @owner, description: "Other")
      Creative.where(id: other.id).update_all(public_id: "BBBBBBBBBB")
      tokens = %w[BBBBBBBBBB CCCCCCCCCC]

      SecureRandom.stub(:alphanumeric, ->(_length) { tokens.shift }) do
        assert_equal "CCCCCCCCCC", @creative.ensure_public_id!
      end
    end

    test "ensure_public_id! gives up after repeated collisions" do
      other = Creative.create!(user: @owner, description: "Other")
      Creative.where(id: other.id).update_all(public_id: "BBBBBBBBBB")
      SecureRandom.stub(:alphanumeric, "BBBBBBBBBB") do
        assert_raises(ActiveRecord::RecordNotSaved) { @creative.ensure_public_id! }
      end
    end

    test "public_slug keeps letters of every script and collapses the rest" do
      assert_equal "hello-public-world", @creative.public_slug
      assert_equal "공개-문서-2026", Creative.public_slug_for("  공개 문서 — 2026!! ")
      assert_equal "", Creative.public_slug_for("!!!")
    end

    test "public_title is the first block of text" do
      assert_equal "Hello, Public World!", @creative.public_title

      @creative.description = "<h2>Plan&nbsp;A</h2><ul><li>Step one</li></ul>"
      assert_equal "Plan A", @creative.public_title

      @creative.description = "<ul><li> </li><li>Second item</li></ul>"
      assert_equal "Second item", @creative.public_title

      @creative.description = "Plain   text"
      assert_equal "Plain text", @creative.public_title

      @creative.description = "<p>#{'word ' * 40}</p>"
      assert_equal 120, @creative.public_title.length
    end

    test "public_slug is capped without a trailing hyphen" do
      slug = Creative.public_slug_for("#{'a' * 59} bcd")

      assert_equal "a" * 59, slug
    end

    test "public_slug of a linked creative uses the origin title" do
      link = Creative.create!(user: users(:two), origin: @creative)

      assert_equal "hello-public-world", link.public_slug
    end
  end
end
