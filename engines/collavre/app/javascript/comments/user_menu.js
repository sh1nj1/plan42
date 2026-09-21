function avatarElement(user, size, classes) {
  const wrapper = document.createElement('span')
  wrapper.className = 'avatar-wrapper'
  wrapper.style.width = `${size}px`
  wrapper.style.height = `${size}px`

  const image = document.createElement('img')
  image.src = user.avatar_url
  image.alt = ''
  image.width = size
  image.height = size
  image.className = classes
  image.title = user.name
  image.dataset.userId = user.id
  image.dataset.userName = user.name
  if (user.email) image.dataset.email = user.email
  wrapper.appendChild(image)

  if (user.default_avatar) {
    const initial = document.createElement('span')
    initial.className = 'avatar-initial'
    initial.style.fontSize = `${Math.round(size / 2)}px`
    initial.textContent = user.initial
    wrapper.appendChild(initial)
  }

  return wrapper
}

export function healthStateFor(user, presentIds, labels) {
  if (!user) return { online: false, kind: 'offline', label: labels.offline }

  const present = (presentIds || []).some((id) => String(id) === String(user.id))
  if (present || user.agent_online === true) {
    return { online: true, kind: 'online', label: labels.online }
  }
  if (!user.ai_user) return { online: false, kind: 'offline', label: labels.offline }

  const kind = ['offline', 'unknown', 'check_error'].includes(user.agent_health_status)
    ? user.agent_health_status
    : 'unknown'
  return { online: false, kind, label: labels[kind] }
}

export function healthStateForUserId(users, userId, presentIds, labels) {
  const user = (users || []).find((entry) => String(entry.id) === String(userId))
  if (user) return healthStateFor(user, presentIds, labels)

  const online = (presentIds || []).some((id) => String(id) === String(userId))
  return { online, kind: online ? 'online' : 'offline', label: online ? labels.online : labels.offline }
}

function menuHeader(user, state, labels) {
  const header = document.createElement('div')
  header.className = 'comment-user-popup-header'
  header.appendChild(avatarElement(user, 36, 'avatar'))

  const identity = document.createElement('div')
  identity.className = 'comment-user-popup-identity'

  const name = document.createElement('strong')
  name.textContent = user.name
  identity.appendChild(name)

  const email = document.createElement('span')
  email.className = 'comment-user-popup-email'
  email.textContent = user.email || ''
  identity.appendChild(email)

  const status = document.createElement('span')
  status.className = `comment-user-popup-status is-${state.kind}`
  status.dataset.commentUserMenuTarget = 'status'
  status.dataset.onlineText = labels.online
  status.dataset.offlineText = labels.offline

  const dot = document.createElement('span')
  dot.className = 'comment-user-popup-status-dot'
  dot.setAttribute('aria-hidden', 'true')
  status.appendChild(dot)

  const statusLabel = document.createElement('span')
  statusLabel.dataset.commentUserMenuTarget = 'statusLabel'
  statusLabel.textContent = state.label
  status.appendChild(statusLabel)
  identity.appendChild(status)
  header.appendChild(identity)

  return header
}

function menuState(online, healthStatus, statusText, labels) {
  return {
    online,
    kind: healthStatus || (online ? 'online' : 'offline'),
    label: statusText || (online ? labels.online : labels.offline),
  }
}

export function createUserMenu({ user, online, healthStatus, statusText, labels, menuId, draggable = false }) {
  const state = menuState(online, healthStatus, statusText, labels)
  const root = document.createElement('div')
  root.className = 'popup-menu-wrapper comment-user-menu'
  root.dataset.controller = 'popup-menu comment-user-menu'
  root.dataset.commentUserMenuUserIdValue = user.id
  root.dataset.commentUserMenuUserNameValue = user.name

  const trigger = document.createElement('button')
  trigger.type = 'button'
  trigger.className = 'popup-menu-toggle comment-user-menu-trigger'
  trigger.dataset.popupMenuTarget = 'button'
  trigger.dataset.action = 'click->popup-menu#toggle'
  trigger.setAttribute('aria-label', labels.open.replace('%{name}', user.name))
  trigger.setAttribute('aria-haspopup', 'menu')
  trigger.setAttribute('aria-expanded', 'false')
  trigger.appendChild(avatarElement(user, 20, `avatar comment-presence-avatar${online ? '' : ' inactive'}`))
  root.appendChild(trigger)

  const menu = document.createElement('div')
  menu.id = menuId
  menu.className = 'popup-menu comment-user-popup'
  menu.dataset.popupMenuTarget = 'menu'
  menu.dataset.action = 'click->popup-menu#menuClick'
  menu.setAttribute('role', 'menu')
  menu.appendChild(menuHeader(user, state, labels))

  const profile = document.createElement('a')
  profile.href = user.profile_url
  profile.className = 'popup-menu-item'
  profile.dataset.action = 'click->comment-user-menu#visitProfile'
  profile.setAttribute('role', 'menuitem')
  profile.textContent = labels.viewProfile
  menu.appendChild(profile)

  const mention = document.createElement('button')
  mention.type = 'button'
  mention.className = 'popup-menu-item'
  mention.dataset.action = 'click->comment-user-menu#mention'
  mention.setAttribute('role', 'menuitem')
  mention.textContent = labels.mention
  menu.appendChild(mention)

  if (draggable) {
    const guide = document.createElement('p')
    guide.className = 'comment-user-popup-guide'
    guide.textContent = labels.dragGuide
    menu.appendChild(guide)
  }

  root.appendChild(menu)
  return root
}
