// Timezone detection
// Auto-detects user's timezone and populates hidden timezone fields

document.addEventListener('turbo:load', () => {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
  document.querySelectorAll('input[name="timezone"]').forEach(el => {
    el.value = tz
  })
})
