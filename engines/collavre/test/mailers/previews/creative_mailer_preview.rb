# Preview all emails at http://localhost:3000/rails/mailers/creative_mailer
class CreativeMailerPreview < ActionMailer::Preview
  # Preview this email at http://localhost:3000/rails/mailers/creative_mailer/in_stock
  def in_stock
    CreativeMailer.in_stock
  end
end
