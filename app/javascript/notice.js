if (!window.noticeInitialized) {
  window.noticeInitialized = true;
  document.addEventListener('turbo:load', function() {
    var noticeBox = document.getElementById('notice-box');
    if (!noticeBox) return;
    var timer = null;
    var clear = function() { noticeBox.innerHTML = ''; };
    noticeBox.addEventListener('DOMNodeInserted', function() {
      if (timer) clearTimeout(timer);
      if (noticeBox.innerHTML.trim() !== '') {
        timer = setTimeout(clear, 5000);
      }
    });
  });
}
