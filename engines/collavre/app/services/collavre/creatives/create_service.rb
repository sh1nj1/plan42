# frozen_string_literal: true

module Collavre
  module Creatives
    # Handles creative creation including sequencing and tagging.
    class CreateService
      Result = Struct.new(:creative, :success?, :errors, keyword_init: true)

      def initialize(creative_params:, user:, child_id: nil, before_id: nil, after_id: nil, tag_ids: nil)
        @creative_params = creative_params
        @user = user
        @child_id = child_id
        @before_id = before_id
        @after_id = after_id
        @tag_ids = Array(tag_ids).compact
      end

      def call
        creative = Creative.new(@creative_params)
        creative.user = creative.parent ? creative.parent.user : @user

        unless creative.save
          return Result.new(creative: creative, success?: false, errors: creative.errors.full_messages)
        end

        reparent_child(creative)
        insert_at_position(creative)
        apply_tags(creative)

        Result.new(creative: creative, success?: true, errors: [])
      end

      private

      def reparent_child(creative)
        return unless @child_id.present?

        child = Creative.find_by(id: @child_id)
        child&.update(parent: creative)
      end

      def insert_at_position(creative)
        if @before_id.present?
          insert_before(creative, @before_id)
        elsif @after_id.present?
          insert_after(creative, @after_id)
        end
      end

      def insert_before(creative, before_id)
        before_creative = Creative.find_by(id: before_id)
        return unless before_creative && before_creative.parent_id == creative.parent_id

        siblings = fetch_siblings(creative)
        index = siblings.index { |s| s.id == before_creative.id } || 0
        siblings.insert(index, creative)
        resequence(siblings)
      end

      def insert_after(creative, after_id)
        after_creative = Creative.find_by(id: after_id)
        return unless after_creative && after_creative.parent_id == creative.parent_id

        siblings = fetch_siblings(creative)
        index = siblings.index { |s| s.id == after_creative.id } || -1
        siblings.insert(index + 1, creative)
        resequence(siblings)
      end

      def fetch_siblings(creative)
        collection = creative.parent ? creative.parent.children.order(:sequence) : Creative.roots.order(:sequence)
        collection.to_a.reject { |s| s.id == creative.id }
      end

      def resequence(siblings)
        siblings.each_with_index { |c, idx| c.update_column(:sequence, idx) }
      end

      def apply_tags(creative)
        @tag_ids.each do |tag_id|
          creative.tags.create(label_id: tag_id)
        end
      end
    end
  end
end
