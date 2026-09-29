# User Manual Test Info

## Create Test User

Create a dedicated account using credentials retrieved from the approved secret store. Assign them to the local
`test_email` and `test_password` variables before running this example.

```ruby
User.create!(
      email: test_email,
      name: "Test User",
      password: test_password,
      password_confirmation: test_password,
      system_admin: false,
      display_level: 6,
      timezone: "UTC",
      email_verified_at: Time.current
    )
```


```md
Test and verify the core functionalities of https://collavre.com

Before you test sign out first if already signed in.
Use a dedicated test account provisioned by an administrator. Retrieve its
credentials from the approved secret store; never commit them to this repository.

Collavre's features are in the Collavre itself, you can visit the features list here URL: https://collavre.com/creatives?id=1
- Items has progress percentage (0% to 100%)
- Only test completed features
- Create "Test Sandbox" Creative (a unit for task in Collavre Product.) and delete it after testing.
- Test the features that are marked as complete (showing as 100%).
- You can skip any feature that requires multiple accounts or is difficult to test with a single account.

Test 10 features only for demo, then stop and prepare a test report summarising the verification results.
```
