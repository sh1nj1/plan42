require "test_helper"

module Creatives
  class IndexQueryLinkedSearchTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)

      # Structure:
      # Folder (id: 100)
      #   -> LinkToFruits (id: 101, origin: Fruits)
      #
      # Fruits (id: 200)
      #   -> Apple (id: 201, "Apple Pie")

      @folder = Creative.create!(user: @user, description: "Folder", sequence: 1)
      @fruits = Creative.create!(user: @user, description: "Fruits", sequence: 2)
      @apple = Creative.create!(user: @user, parent: @fruits, description: "Apple Pie", sequence: 1)

      @link = Creative.create!(user: @user, parent: @folder, origin: @fruits, sequence: 1)
    end

    test "search finds direct descendants" do
      # Search "Apple" in Fruits -> Find Apple matches
      params = { search: "Apple", id: @fruits.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      assert_includes result.creatives, @apple
    end

    test "search does NOT find linked descendants currently" do
      # Search "Apple" in Folder -> Should find via Link
      # Currently expected to FAIL (return empty)
      params = { search: "Apple", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      # In the optimized version, we want this to be true.
      assert_includes result.creatives, @apple
    end
  end
end
