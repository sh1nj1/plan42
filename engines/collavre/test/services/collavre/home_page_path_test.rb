# frozen_string_literal: true

require "test_helper"

module Collavre
  class HomePagePathTest < ActiveSupport::TestCase
    setup do
      SystemSetting.where(key: "home_page_path_authenticated").destroy_all
      Rails.cache.clear
    end

    teardown do
      SystemSetting.where(key: "home_page_path_authenticated").destroy_all
      Rails.cache.clear
    end

    test "mount_relative returns the configured path when the app is not mounted" do
      set_home("/creatives")

      assert_equal "/creatives", HomePagePath.mount_relative
      assert_equal "/creatives", HomePagePath.mount_relative(script_name: "")
    end

    test "mount_relative strips a trailing slash" do
      set_home("/creatives/")

      assert_equal "/creatives", HomePagePath.mount_relative
    end

    test "mount_relative strips the engine mount prefix" do
      set_home("/collavre/creatives")

      assert_equal "/creatives", HomePagePath.mount_relative(script_name: "/collavre")
    end

    test "mount_relative keeps paths that only share a prefix with the mount" do
      set_home("/collavre-docs/creatives")

      assert_equal "/collavre-docs/creatives", HomePagePath.mount_relative(script_name: "/collavre")
    end

    test "mount_relative returns an empty path for the root sentinel" do
      set_home("/")

      assert_equal "", HomePagePath.mount_relative
    end

    test "absolute returns the configured path when the app is not mounted" do
      set_home("/users")

      assert_equal "/users", HomePagePath.absolute
    end

    test "absolute applies the engine mount prefix" do
      set_home("/creatives")

      assert_equal "/collavre/creatives", HomePagePath.absolute(script_name: "/collavre")
    end

    test "absolute leaves an already mounted path untouched" do
      set_home("/collavre/creatives")

      assert_equal "/collavre/creatives", HomePagePath.absolute(script_name: "/collavre")
    end

    test "absolute treats the mount itself as already mounted" do
      set_home("/collavre")

      assert_equal "/collavre", HomePagePath.absolute(script_name: "/collavre/")
    end

    test "absolute is nil for the root sentinel so callers fall back to the app root" do
      set_home("/")

      assert_nil HomePagePath.absolute
    end

    test "absolute falls back to the default home page when unset" do
      assert_equal "/creatives", HomePagePath.absolute
    end

    private

    def set_home(value)
      SystemSetting.create!(key: "home_page_path_authenticated", value: value)
      Rails.cache.clear
    end
  end
end
