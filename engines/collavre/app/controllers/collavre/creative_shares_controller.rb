module Collavre
  class CreativeSharesController < ApplicationController
    def create
      @creative = Creative.find(params[:creative_id]).effective_origin

      user = nil
      if params[:user_email].present?
        user = User.find_by(email: params[:user_email])
        unless user
          invitation = Invitation.create!(email: params[:user_email], inviter: Current.user, creative: @creative, permission: params[:permission])
          InvitationMailer.with(invitation: invitation).invite.deliver_later
          flash[:notice] = t("collavre.invites.invite_sent")
          redirect_back(fallback_location: creatives_path) and return
        end
      end

      permission = params[:permission]

      # Enforce read-only for public shares (no user email provided)
      if params[:user_email].blank? && permission != "no_access" && permission != "read"
        permission = "read"
      end

      ancestor_ids = @creative.ancestors.pluck(:id)
      ancestor_shares = CreativeShare.where(creative_id: ancestor_ids, user: user)
                                     .where("permission >= ? or permission = ?", CreativeShare.permissions[permission], CreativeShare.permissions[:no_access])
      closest_parent_share = CreativeShare.closest_parent_share(ancestor_ids, ancestor_shares)

      is_param_no_access = permission == :no_access.to_s
      Rails.logger.debug "### closest_parent_share = #{closest_parent_share.inspect}, is_param_no_access: #{is_param_no_access}"
      if closest_parent_share.present?
        if closest_parent_share.permission == :no_access.to_s
          flash[:alert] = t("collavre.creatives.share.can_not_share_by_no_access_in_parent")
          redirect_back(fallback_location: creatives_path) and return
        else
          if is_param_no_access
            # can set!
          else
            flash[:alert] = t("collavre.creatives.share.already_shared_in_parent")
            redirect_back(fallback_location: creatives_path) and return
          end
        end
      end

      share = CreativeShare.find_or_initialize_by(creative: @creative, user: user)
      share.shared_by ||= Current.user
      share.permission = permission
      if share.save and not is_param_no_access
        if user
          @creative.create_linked_creative_for_user(user)
          Contact.ensure(user: Current.user, contact_user: user)
          Contact.ensure(user: @creative.user, contact_user: user)
        end
        flash[:notice] = t("collavre.creatives.share.shared")
      else
        flash[:alert] = share.errors.full_messages.to_sentence
      end
      redirect_back(fallback_location: creatives_path)
    end

    def destroy
      @creative_share = CreativeShare.find(params[:id])
      @creative_share.destroy
      # remove linked creative if it exists
      linked_creative = Creative.find_by(origin_id: @creative_share.creative_id, user_id: @creative_share.user_id)
      linked_creative&.destroy
      respond_to do |format|
        format.html { redirect_back fallback_location: main_app.root_path, notice: t("collavre.creatives.index.share_deleted") }
        format.json { head :no_content }
      end
    end

    private

      def all_descendants(creative)
        creative.children.flat_map { |child| [ child ] + all_descendants(child) }
      end
  end
end
