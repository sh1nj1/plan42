# frozen_string_literal: true

require "test_helper"

class Navigation::RegistryTest < ActiveSupport::TestCase
  setup do
    @registry = Navigation::Registry.instance
    @registry.reset!
  end

  teardown do
    @registry.reset!
  end

  test "register adds a navigation item" do
    @registry.register(key: :test_item, label: "Test", type: :button, path: "/test")

    assert_equal 1, @registry.all.size
    assert_equal :test_item, @registry.all.first[:key]
  end

  test "register normalizes item with defaults" do
    @registry.register(key: :test_item, label: "Test")

    item = @registry.find(:test_item)
    assert_equal :main, item[:section]
    assert_equal 500, item[:priority]
    assert_equal :button, item[:type]
    assert_equal true, item[:desktop]
    assert_equal true, item[:mobile]
    assert_equal false, item[:requires_auth]
    assert_equal false, item[:requires_user]
  end

  test "register replaces existing item with same key" do
    @registry.register(key: :test_item, label: "Original")
    @registry.register(key: :test_item, label: "Updated")

    assert_equal 1, @registry.all.size
    assert_equal "Updated", @registry.find(:test_item)[:label]
  end

  test "register requires key" do
    assert_raises(ArgumentError) do
      @registry.register(label: "Test")
    end
  end

  test "register requires label" do
    assert_raises(ArgumentError) do
      @registry.register(key: :test_item)
    end
  end

  test "register validates type" do
    assert_raises(ArgumentError) do
      @registry.register(key: :test_item, label: "Test", type: :invalid)
    end
  end

  test "unregister removes item by key" do
    @registry.register(key: :test_item, label: "Test")
    @registry.unregister(:test_item)

    assert_nil @registry.find(:test_item)
    assert_empty @registry.all
  end

  test "modify updates existing item" do
    @registry.register(key: :test_item, label: "Original", priority: 100)
    @registry.modify(:test_item, label: "Updated", priority: 200)

    item = @registry.find(:test_item)
    assert_equal "Updated", item[:label]
    assert_equal 200, item[:priority]
  end

  test "modify raises error for non-existent item" do
    assert_raises(ArgumentError) do
      @registry.modify(:non_existent, label: "Test")
    end
  end

  test "add_child adds child to parent" do
    @registry.register(key: :parent, label: "Parent")
    @registry.add_child(:parent, key: :child, label: "Child")

    parent = @registry.find(:parent)
    assert_equal 1, parent[:children].size
    assert_equal :child, parent[:children].first[:key]
  end

  test "add_child replaces existing child with same key" do
    @registry.register(key: :parent, label: "Parent")
    @registry.add_child(:parent, key: :child, label: "Original")
    @registry.add_child(:parent, key: :child, label: "Updated")

    parent = @registry.find(:parent)
    assert_equal 1, parent[:children].size
    assert_equal "Updated", parent[:children].first[:label]
  end

  test "add_child raises error for non-existent parent" do
    assert_raises(ArgumentError) do
      @registry.add_child(:non_existent, key: :child, label: "Child")
    end
  end

  test "items_for_section returns items in specific section sorted by priority" do
    @registry.register(key: :item1, label: "Item 1", section: :main, priority: 200)
    @registry.register(key: :item2, label: "Item 2", section: :main, priority: 100)
    @registry.register(key: :item3, label: "Item 3", section: :user, priority: 50)

    main_items = @registry.items_for_section(:main)
    assert_equal 2, main_items.size
    assert_equal :item2, main_items.first[:key]
    assert_equal :item1, main_items.last[:key]

    user_items = @registry.items_for_section(:user)
    assert_equal 1, user_items.size
    assert_equal :item3, user_items.first[:key]
  end

  test "all returns items sorted by priority" do
    @registry.register(key: :item1, label: "Item 1", priority: 300)
    @registry.register(key: :item2, label: "Item 2", priority: 100)
    @registry.register(key: :item3, label: "Item 3", priority: 200)

    items = @registry.all
    assert_equal [:item2, :item3, :item1], items.map { |i| i[:key] }
  end

  test "reset clears all items" do
    @registry.register(key: :item1, label: "Item 1")
    @registry.register(key: :item2, label: "Item 2")
    @registry.reset!

    assert_empty @registry.all
  end

  test "find returns item by key" do
    @registry.register(key: :test_item, label: "Test")

    assert_equal :test_item, @registry.find(:test_item)[:key]
    assert_nil @registry.find(:non_existent)
  end

  test "children added via add_child are sorted by priority" do
    @registry.register(key: :parent, label: "Parent")
    @registry.add_child(:parent, key: :child1, label: "Child 1", priority: 200)
    @registry.add_child(:parent, key: :child2, label: "Child 2", priority: 100)
    @registry.add_child(:parent, key: :child3, label: "Child 3", priority: 150)

    parent = @registry.find(:parent)
    assert_equal [:child2, :child3, :child1], parent[:children].map { |c| c[:key] }
  end

  test "children passed via register are sorted by priority" do
    @registry.register(
      key: :parent,
      label: "Parent",
      children: [
        { key: :child1, label: "Child 1", priority: 200 },
        { key: :child2, label: "Child 2", priority: 100 },
        { key: :child3, label: "Child 3", priority: 150 }
      ]
    )

    parent = @registry.find(:parent)
    assert_equal [:child2, :child3, :child1], parent[:children].map { |c| c[:key] }
  end
end
