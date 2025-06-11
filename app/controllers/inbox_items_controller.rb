class InboxItemsController < ApplicationController
  before_action :set_inbox_item, only: [:update, :destroy]

  def index
    scope = InboxItem.where(owner: Current.user).order(created_at: :desc)
    scope = scope.new_items unless params[:show] == 'all'
    @inbox_items = scope
    render partial: "inbox_items/list", locals: { items: @inbox_items }
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
