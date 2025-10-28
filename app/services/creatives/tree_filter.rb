module Creatives
  class TreeFilter
    def initialize(user:, params: {})
      @user = user
      @params = normalize_params(params)
      @tag_ids = Array(@params[:tags]).map(&:presence).compact.map(&:to_s)
      @min_progress = parse_progress(@params[:min_progress])
      @max_progress = parse_progress(@params[:max_progress])
      @comment_only = @params[:comment].to_s == "true"
      @children_cache = {}
      @visible_cache = {}
      @has_children_cache = {}
      @visible_children_cache = {}
      @tag_cache = {}
    end

    def filters_active?
      @filters_active ||= @tag_ids.any? || !@min_progress.nil? || !@max_progress.nil?
    end

    def visible?(creative)
      @visible_cache.fetch(creative.id) do
        @visible_cache[creative.id] = filters_active? ? matches_filters?(creative) : true
      end
    end

    def has_children?(creative)
      return false if comment_only?

      if !filters_active?
        children_for(creative).any?
      else
        @has_children_cache.fetch(creative.id) do
          @has_children_cache[creative.id] = children_for(creative).any? do |child|
            visible?(child) || has_children?(child)
          end
        end
      end
    end

    def visible_children_of(creative)
      return [] if comment_only?

      if !filters_active?
        children_for(creative)
      else
        @visible_children_cache.fetch(creative.id) do
          @visible_children_cache[creative.id] = children_for(creative).flat_map do |child|
            if visible?(child)
              [ child ]
            else
              visible_children_of(child)
            end
          end
        end
      end
    end

    private

    attr_reader :user, :tag_ids, :min_progress, :max_progress

    def normalize_params(params)
      raw = if params.respond_to?(:to_unsafe_h)
              params.to_unsafe_h
            elsif params.respond_to?(:to_h)
              params.to_h
            else
              params
            end
      (raw || {}).with_indifferent_access
    end

    def comment_only?
      @comment_only
    end

    def parse_progress(value)
      return nil if value.nil?
      str = value.to_s
      return nil if str.blank?
      Float(str)
    rescue ArgumentError
      nil
    end

    def matches_filters?(creative)
      if tag_ids.any?
        creative_tag_ids = tag_ids_for(creative)
        return false if (creative_tag_ids & tag_ids).empty?
      end

      if !min_progress.nil?
        return false if creative.progress < min_progress
      end

      if !max_progress.nil?
        return false if creative.progress > max_progress
      end

      true
    end

    def children_for(creative)
      @children_cache.fetch(creative.id) do
        @children_cache[creative.id] = creative.children_with_permission(user)
      end
    end

    def tag_ids_for(creative)
      @tag_cache.fetch(creative.id) do
        @tag_cache[creative.id] = creative.tags.pluck(:label_id).map(&:to_s)
      end
    end
  end
end
