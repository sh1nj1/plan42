Jails.component('comment-participants', function(element) {
  var users = [];
  var present = [];
  function avatarHtml(u) {
    var inactive = present.indexOf(u.id) === -1;
    var emailAttr = u.email ? (' data-email="' + u.email + '"') : '';
    var span = u.default_avatar ? ('<span class="avatar-initial" style="font-size:' + Math.round(20 / 2) + 'px">' + u.initial + '</span>') : '';
    return '<div class="avatar-wrapper" style="width:20px;height:20px">' +
      '<img src="' + u.avatar_url + '" alt="" width="20" height="20" class="avatar comment-presence-avatar' + (inactive ? ' inactive' : '') + '" title="' + u.name + '" style="border-radius:50%;vertical-align:middle"' + emailAttr + '>' +
      span +
      '</div>';
  }
  function render() {
    element.innerHTML = users.map(avatarHtml).join('');
  }
  return {
    mount: render,
    setUsers: function(data) { users = data; render(); },
    setPresent: function(ids) { present = ids; render(); }
  };
});

document.addEventListener('DOMContentLoaded', function() { Jails.mount(); });
