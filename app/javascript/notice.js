if (!window.noticeInitialized) {
  window.noticeInitialized = true;
  document.addEventListener('turbo:load', function() {
    var noticeBox = document.getElementById('notice-box');
    if (!noticeBox) return;
    var timer = null;
    var clear = function() { noticeBox.innerHTML = ''; };
    noticeBox.addEventListener('DOMNodeInserted', function(e) {
      if (timer) clearTimeout(timer);
      if (noticeBox.innerHTML.trim() === '') return;
      var popup = document.getElementById('comments-popup');
      var inserted = e.target;
      var creativeId = inserted.dataset ? inserted.dataset.creativeId : null;
      if (popup && popup.style.display === 'block' && popup.dataset.creativeId === creativeId) {
        clear();
        return;
      }
      timer = setTimeout(clear, 5000);
    });
  });
}
