class ContactsController < ApplicationController
  def create
    email = contact_params[:email].to_s.strip.downcase

    if email.blank?
      redirect_back fallback_location: user_path(Current.user, tab: "contacts"), alert: t("contacts.errors.email_required")
      return
    end

    contact_user = User.find_by("LOWER(email) = ?", email)

    unless contact_user
      redirect_back fallback_location: user_path(Current.user, tab: "contacts"), alert: t("contacts.errors.not_found")
      return
    end

    if contact_user == Current.user
      redirect_back fallback_location: user_path(Current.user, tab: "contacts"), alert: t("contacts.errors.self_add")
      return
    end

    contact = Contact.find_or_initialize_by(user: Current.user, contact_user: contact_user)
    if contact.persisted? || contact.save
      redirect_to user_path(Current.user, tab: "contacts"), notice: t("contacts.notices.added", name: contact_user.display_name)
    else
      redirect_back fallback_location: user_path(Current.user, tab: "contacts"), alert: contact.errors.full_messages.to_sentence
    end
  end

  def destroy
    contact = Current.user.contacts.find(params[:id])
    contact.destroy
    redirect_to user_path(Current.user, tab: "contacts", contact_page: params[:contact_page]), notice: t("contacts.notices.removed")
  end

  private

  def contact_params
    params.require(:contact).permit(:email)
  end
end
