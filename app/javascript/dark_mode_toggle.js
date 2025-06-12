// 다크모드 토글 스크립트
function setupDarkModeToggle() {
  const currentTheme = document.body.dataset.theme === 'dark' ? 'dark' : 'light';
  let theme = currentTheme;

  if (!document.getElementById('dark-mode-toggle')) {
    const btn = document.createElement('button');
    btn.id = 'dark-mode-toggle';
    btn.style.position = 'fixed';
    btn.style.bottom = '20px';
    btn.style.right = '20px';
    btn.style.zIndex = '9999';
    btn.style.padding = '8px 16px';
    btn.style.borderRadius = '8px';
    btn.style.border = 'none';
    btn.style.cursor = 'pointer';
    btn.style.boxShadow = '0 2px 8px rgba(0,0,0,0.15)';

    const updateAppearance = () => {
      btn.textContent = theme === 'dark' ? '☀️ 라이트모드' : '🌙 다크모드';
      btn.style.background = theme === 'dark' ? '#fff' : '#444';
      btn.style.color = theme === 'dark' ? '#222' : '#fff';
    };

    updateAppearance();
    document.body.appendChild(btn);

    btn.addEventListener('click', () => {
      theme = theme === 'dark' ? 'light' : 'dark';
      updateAppearance();
      fetch('/theme', {
        method: 'PATCH',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('meta[name=csrf-token]').content
        },
        body: JSON.stringify({ theme })
      }).then(() => {
        location.reload();
      });
    });
  }
}

document.addEventListener('turbo:load', setupDarkModeToggle);
