// 다크모드 토글 스크립트
function setupDarkModeToggle() {
  // 현재 모드 확인(로컬스토리지)
  let isDark;
  if (localStorage.getItem('darkMode') !== null) {
    isDark = localStorage.getItem('darkMode') === 'true';
  } else {
    isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  }
  if (isDark) {
    document.body.classList.add('dark-mode');
  }
  console.log("isDark", isDark);

  // 토글 버튼 생성(이미 있으면 생략)
  if (!document.getElementById('dark-mode-toggle')) {
    const btn = document.createElement('button');
    btn.id = 'dark-mode-toggle';
    btn.textContent = isDark ? '☀️ 라이트모드' : '🌙 다크모드';
    btn.style.position = 'fixed';
    btn.style.bottom = '20px';
    btn.style.right = '20px';
    btn.style.zIndex = '9999';
    btn.style.padding = '8px 16px';
    btn.style.borderRadius = '8px';
    btn.style.border = 'none';
    btn.style.background = isDark ? '#fff' : '#444';
    btn.style.color = isDark ? '#222' : '#fff';
    btn.style.cursor = 'pointer';
    btn.style.boxShadow = '0 2px 8px rgba(0,0,0,0.15)';
    document.body.appendChild(btn);

    btn.addEventListener('click', () => {
      const isDarkNow = document.body.classList.toggle('dark-mode');
      localStorage.setItem('darkMode', isDarkNow);
      btn.textContent = isDarkNow ? '☀️ 라이트모드' : '🌙 다크모드';
      btn.style.background = isDarkNow ? '#fff' : '#444';
      btn.style.color = isDarkNow ? '#222' : '#fff';
    });
  }
}

document.addEventListener('turbo:load', setupDarkModeToggle);
