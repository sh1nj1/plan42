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

    test "search finds linked descendants" do
      # Search "Apple" in Folder -> Should find via Link
      params = { search: "Apple", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      # In the optimized version, we want this to be true.
      assert_includes result.creatives, @apple
    end
    test "search finds linked descendants via comment content" do
      # Create a comment on the Apple creative
      @apple.comments.create!(user: @user, content: "This is a tasty fruit description")

      # Search for "tasty" in Folder -> Should find Apple via Link
      params = { search: "tasty", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      assert_includes result.creatives, @apple
    end

    test "search filters out linked descendants if user lacks permission" do
      # Create a private creative for another user
      other_user = users(:two)
      private_fruits = Creative.create!(user: other_user, description: "Private Fruits", sequence: 3)
      Creative.create!(user: other_user, parent: private_fruits, description: "Private Apple", sequence: 1)

      # Link to private fruits in our folder
      # Normally we can't create a link to something we can't see, but let's assume the link exists
      # or checking logic handles existing links to now-private content.
      Creative.create!(user: @user, parent: @folder, origin: private_fruits, sequence: 2)

      # Search for "Private Apple"
      params = { search: "Private Apple", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      # Should NOT find private_apple because @user cannot read private_fruits tree
      assert_empty result.creatives
    end

    test "search handles duplicate paths gracefully" do
      # Create a second link to the same Fruits origin
      Creative.create!(user: @user, parent: @folder, origin: @fruits, sequence: 2)

      # Search "Apple" -> Should find Apple, but only once
      params = { search: "Apple", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      assert_includes result.creatives, @apple
      assert_equal 1, result.creatives.count { |c| c.id == @apple.id }
    end

    test "search returns origin node itself if it matches" do
      # Search "Fruits" inside Folder
      # Should find Fruits (which is the Origin of LinkToFruits)
      params = { search: "Fruits", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      # The search should return the Origin node "Fruits" because it's linked
      assert_includes result.creatives, @fruits
    end

    test "search does not traverse recursive links (one-hop guard)" do
      # Create a structure:
      # @folder -> LinkToFruits (@link) -> @fruits
      #
      # Now add a "recursive" situation or nested link.
      # Create another origin "BananaTree" containing "Banana"
      banana_tree = Creative.create!(user: @user, description: "BananaTree", sequence: 3)
      banana = Creative.create!(user: @user, parent: banana_tree, description: "Banana", sequence: 1)

      # Link "Fruits" to "BananaTree"
      # Fruits -> LinkToBanana -> BananaTree
      Creative.create!(user: @user, parent: @fruits, origin: banana_tree, sequence: 2)

      # Search "Banana" in Folder
      # Path: Folder -> LinkToFruits -> Fruits -> LinkToBanana -> BananaTree -> Banana
      # Current logic only supports one level of link traversal (Folder -> Link -> Origin -> Descendants)
      # It does NOT perform recursive link traversal (Origin -> Link -> Origin2 -> ...).

      params = { search: "Banana", id: @folder.id }
      query = IndexQuery.new(user: @user, params: params)
      result = query.call

      # Should NOT find Banana because it requires two hops of links
      assert_not_includes result.creatives, banana
    end
  end
end
