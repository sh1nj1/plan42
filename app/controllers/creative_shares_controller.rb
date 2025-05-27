class CreativeSharesController < ApplicationController
  def create
    @creative = Creative.find(params[:creative_id])
    user = User.find_by(email_address: params[:user_email])
    unless user
      flash[:alert] = "User not found"
      redirect_back(fallback_location: creatives_path) and return
    end

    permission = params[:permission]

    # Helper to collect all descendants
    def all_descendants(creative)
      creative.children.flat_map { |child| [ child ] + all_descendants(child) }
    end

    shares = [ CreativeShare.new(creative: @creative, user: user, permission: permission) ]

    if permission.ends_with?("_tree")
      all_descendants(@creative).each do |descendant|
        shares << CreativeShare.new(creative: descendant, user: user, permission: permission)
      end
    end

    if shares.all?(&:save)
      flash[:notice] = "Creative shared!"
    else
      flash[:alert] = shares.map { |s| s.errors.full_messages }.flatten.to_sentence
    end
    redirect_back(fallback_location: creatives_path)
  end
end
