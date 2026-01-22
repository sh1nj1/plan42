module Collavre
  class InboxItemsController < ApplicationController
    before_action :set_inbox_item, only: [ :update, :destroy ]

    PER_PAGE = 20

    def index
      scope = InboxItem.where(owner: Current.user).order(created_at: :desc)
      scope = scope.new_items unless params[:show] == "all"

      per_page = params[:per_page].presence&.to_i || PER_PAGE
      per_page = PER_PAGE if per_page <= 0 || per_page > 100
      page = params[:page].presence&.to_i || 1
      page = 1 if page < 1
      offset = (page - 1) * per_page

      items = scope.offset(offset).limit(per_page + 1).to_a
      @inbox_items = items.first(per_page)
      @next_page = items.length > per_page ? page + 1 : nil

      respond_to do |format|
        format.html do
          render partial: "inbox_items/list", locals: { items: @inbox_items, next_page: @next_page }
        end
        format.json do
          render json: {
            items_html: render_to_string(partial: "inbox_items/items", formats: [ :html ], locals: { items: @inbox_items }),
            next_page: @next_page,
            empty: @inbox_items.empty?
          }
        end
      end
    end

    def count
      c = InboxItem.where(owner: Current.user, state: "new").count
      render json: { count: c }
    end

    def update
      if @inbox_item.owner == Current.user
        @inbox_item.update(state: params[:state])
        head :no_content
      else
        head :forbidden
      end
    end

    def destroy
      if @inbox_item.owner == Current.user
        @inbox_item.destroy
        head :no_content
      else
        head :forbidden
      end
    end

    private

    def set_inbox_item
      @inbox_item = InboxItem.find(params[:id])
    end
  end
end
