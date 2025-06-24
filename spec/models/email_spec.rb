require 'rails_helper'

RSpec.describe Email, type: :model do
  it "is valid with minimal attributes" do
    email = described_class.new(
      email: "test@example.com",
      subject: "Hello",
      body: "body",
      event: :invitation
    )
    expect(email).to be_valid
  end
end
