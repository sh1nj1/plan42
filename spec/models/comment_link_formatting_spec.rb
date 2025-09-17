require "rails_helper"

RSpec.describe Comment, type: :model do
  describe "link preview formatting" do
    it "formats content before saving" do
      user = User.create!(email: "user@example.com", password: "password", name: "User")
      creative = Creative.create!(user: user, description: "Root")
      formatter = instance_double(CommentLinkFormatter)

      expect(CommentLinkFormatter).to receive(:new).and_return(formatter)
      expect(formatter).to receive(:format).and_return("formatted content")

      comment = Comment.create!(creative: creative, user: user, content: "https://example.com")
      expect(comment.content).to eq("formatted content")
    end
  end
end
