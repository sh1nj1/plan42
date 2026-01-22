# User Manual Test Info

## Create Test User

You can create test user without email verification by app console.

```ruby
User.create!(
      email: "tester@example.com",
      name: "Test User",
      password: "Tester42$@",
      password_confirmation: "Tester42$@",
      system_admin: false,
      display_level: 6,
      timezone: "UTC",
      email_verified_at: Time.current
    )
```


```md
Test and verify the core functionalities of https://collavre.com

Before you test sign out first if already signed in.
Use the following login credentials:

Email: tester@example.com
Password: Tester42$@

Collavre's features are in the Collavre itself, you can visit the features list here URL: https://collavre.com/creatives?id=1
- Items has progress percentage (0% to 100%)
- Only test completed features
- Create "Test Sandbox" Creative (a unit for task in Collavre Product.) and delete it after testing.
- Test the features that are marked as complete (showing as 100%).
- You can skip any feature that requires multiple accounts or is difficult to test with a single account.

Test 10 features only for demo, then stop and prepare a test report summarising the verification results.
```
