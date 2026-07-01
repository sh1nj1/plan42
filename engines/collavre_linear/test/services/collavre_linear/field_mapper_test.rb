# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class FieldMapperTest < ActiveSupport::TestCase
    # ---------------------------------------------------------------------------
    # Helpers — pure Ruby stubs, no DB
    # ---------------------------------------------------------------------------

    # Minimal creative stub: exposes only the columns the mapper may read.
    # Deliberately does NOT expose #progress so any accidental read raises NoMethodError.
    CreativeStub = Struct.new(:title, :description, :sequence, :data, keyword_init: true)

    def make_creative(title: "My Task", description: "Body", sequence: nil, linear_data: {})
      data = linear_data.empty? ? {} : { "linear" => linear_data }
      CreativeStub.new(title: title, description: description, sequence: sequence, data: data)
    end

    # Issue payload as a plain hash (mirrors what the webhook / API returns)
    def make_issue(title: "Linear Issue", description: "Desc", priority: 0,
                   state: nil, labels: [], assignee: nil)
      {
        "title" => title,
        "description" => description,
        "priority" => priority,
        "state" => state,
        "labels" => { "nodes" => labels },
        "assignee" => assignee
      }
    end

    # ---------------------------------------------------------------------------
    # creative_to_issue_attrs (outbound)
    # ---------------------------------------------------------------------------

    test "outbound: sequence 2 maps to priority 2" do
      creative = make_creative(sequence: 2)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal 2, attrs[:priority]
    end

    test "outbound: sequence 1 maps to priority 1 (Urgent)" do
      creative = make_creative(sequence: 1)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal 1, attrs[:priority]
    end

    test "outbound: sequence 4 maps to priority 4 (Low)" do
      creative = make_creative(sequence: 4)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal 4, attrs[:priority]
    end

    test "outbound: sequence 5 (None sentinel) maps to priority 0" do
      creative = make_creative(sequence: 5)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal 0, attrs[:priority]
    end

    test "outbound: nil sequence maps to priority 0 (None)" do
      creative = make_creative(sequence: nil)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal 0, attrs[:priority]
    end

    test "outbound: title and description are passed through" do
      creative = make_creative(title: "Hello", description: "World", sequence: 2)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal "Hello", attrs[:title]
      assert_equal "World", attrs[:description]
    end

    test "outbound: state_id is included when present in creative.data[linear]" do
      creative = make_creative(linear_data: { "state" => { "id" => "state-abc", "name" => "In Progress" } })
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal "state-abc", attrs[:state_id]
    end

    test "outbound: state_id is absent when no state in creative.data[linear]" do
      creative = make_creative
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      refute attrs.key?(:state_id)
    end

    test "outbound: label_ids included when labels present in creative.data[linear]" do
      creative = make_creative(
        linear_data: {
          "labels" => [{ "id" => "lbl-1", "name" => "Bug" }, { "id" => "lbl-2", "name" => "Frontend" }]
        }
      )
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      assert_equal %w[lbl-1 lbl-2], attrs[:label_ids]
    end

    test "outbound: label_ids absent when no labels in creative.data[linear]" do
      creative = make_creative
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      refute attrs.key?(:label_ids)
    end

    test "outbound: progress key is NOT in the output" do
      creative = make_creative(sequence: 2)
      attrs = FieldMapper.creative_to_issue_attrs(creative)
      refute attrs.key?(:progress), "progress must never appear in outbound attrs"
    end

    # ---------------------------------------------------------------------------
    # issue_to_creative_attrs (inbound)
    # ---------------------------------------------------------------------------

    test "inbound: priority 1 yields sequence 1" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 1))
      assert_equal 1, attrs[:sequence]
    end

    test "inbound: priority 2 yields sequence 2" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 2))
      assert_equal 2, attrs[:sequence]
    end

    test "inbound: priority 3 yields sequence 3" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 3))
      assert_equal 3, attrs[:sequence]
    end

    test "inbound: priority 4 yields sequence 4" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 4))
      assert_equal 4, attrs[:sequence]
    end

    test "inbound: priority 0 (None) yields sequence 5 (last)" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 0))
      assert_equal 5, attrs[:sequence]
    end

    test "inbound: title and description are passed through" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(title: "T", description: "D"))
      assert_equal "T", attrs[:title]
      assert_equal "D", attrs[:description]
    end

    test "inbound: state is mirrored into data_linear[:state]" do
      state = { "id" => "state-xyz", "name" => "Done", "type" => "completed" }
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(state: state))
      assert_equal state, attrs[:data_linear][:state]
    end

    test "inbound: labels nodes are mirrored into data_linear[:labels]" do
      labels = [{ "id" => "lbl-1", "name" => "Bug" }]
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(labels: labels))
      assert_equal labels, attrs[:data_linear][:labels]
    end

    test "inbound: assignee is mirrored into data_linear[:assignee]" do
      assignee = { "id" => "usr-1", "name" => "Alice", "email" => "alice@example.com" }
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(assignee: assignee))
      assert_equal assignee, attrs[:data_linear][:assignee]
    end

    test "inbound: nil state yields nil in data_linear[:state]" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(state: nil))
      assert_nil attrs[:data_linear][:state]
    end

    test "inbound: nil assignee yields nil in data_linear[:assignee]" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(assignee: nil))
      assert_nil attrs[:data_linear][:assignee]
    end

    test "inbound: empty labels yields empty array in data_linear[:labels]" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(labels: []))
      assert_equal [], attrs[:data_linear][:labels]
    end

    test "inbound: progress key is NOT in the output" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue(priority: 2))
      refute attrs.key?(:progress), "progress must never appear in inbound attrs"
    end

    test "inbound: data_linear key is present and is a Hash" do
      attrs = FieldMapper.issue_to_creative_attrs(make_issue)
      assert_kind_of Hash, attrs[:data_linear]
    end
  end
end
