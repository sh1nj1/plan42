class CreativeSharesController < ApplicationController
  def create
    @creative = Creative.find(params[:creative_id])
    user = User.find_by(email: params[:user_email])
    unless user
      flash[:alert] = "User not found"
      redirect_back(fallback_location: creatives_path) and return
    end

    permission = params[:permission]

    shares = [ CreativeShare.new(creative: @creative, user: user, permission: permission) ]

    if permission.ends_with?("_tree")
      all_descendants(@creative).each do |descendant|
        shares << CreativeShare.new(creative: descendant, user: user, permission: permission)
      end
    end

    if shares.all?(&:save)
      create_linked_creative_for_user user, @creative
      flash[:notice] = "Creative shared!"
    else
      flash[:alert] = shares.map { |s| s.errors.full_messages }.flatten.to_sentence
    end
    redirect_back(fallback_location: creatives_path)
  end

  private

    def all_descendants(creative)
      creative.children.flat_map { |child| [ child ] + all_descendants(child) }
    end

    def create_linked_creative_for_user(user, to_creative)
      # 만약 creative 가 이미 Linked Creative 면, origin 을 사용해야 함.
      creative = to_creative.effective_origin
      return if creative.user_id == user.id
      # 이미 Linked Creative가 있으면 생성하지 않음
      linked = Creative.find_by(origin_id: creative.id, user_id: user.id)
      return if linked
      linked = Creative.new(origin_id: creative.id, user_id: user.id, parent_id: nil)
      linked.save!
    end
end
