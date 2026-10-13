module Collavre
  module CreativesIndexTitle
    private

    def prepare_index_title
      @shared_list = @parent_creative ? @parent_creative.all_shared_users : []
      return unless @parent_creative && params[:tags].present?
      return unless Creatives::FilterState.new(index_query_params.except("tags")).active?

      @progress_map = Creatives::IndexQuery.new(user: Current.user, params: index_query_params).call.progress_map
      @parent_creative.filtered_progress = @progress_map.fetch(@parent_creative.id.to_s, 0)
    end

    def index_query_params
      params.permit(
        :id, :simple, :search, :search_mode, :comment, :has_comments, :has_cron, :reaction_emoji,
        :min_progress, :max_progress, :due_before, :due_after, :has_due_date,
        :assignee_id, :unassigned, :show_archived, :page, :per_page,
        tags: []
      ).to_h
    end
  end
end
