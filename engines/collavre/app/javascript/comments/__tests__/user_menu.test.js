/**
 * @jest-environment jsdom
 */
import { createUserMenu } from '../user_menu'

const LABELS = {
  open: 'Open %{name}\'s profile menu',
  viewProfile: 'View profile',
  mention: 'Mention',
  dragGuide: 'Drag this avatar to a topic.',
  online: 'Online',
  offline: 'Offline',
}

const USER = {
  id: 9,
  name: 'Agent One',
  email: 'agent@example.com',
  avatar_url: '/agent.png',
  profile_url: '/users/9',
  default_avatar: false,
  initial: 'A',
}

describe('createUserMenu', () => {
  test('builds the complete online profile menu without drag guidance', () => {
    const menu = createUserMenu({
      user: USER,
      online: true,
      labels: LABELS,
      menuId: 'participant-user-menu-9',
    })

    expect(menu.dataset.controller).toBe('popup-menu comment-user-menu')
    expect(menu.dataset.commentUserMenuUserIdValue).toBe('9')
    expect(menu.dataset.commentUserMenuUserNameValue).toBe('Agent One')
    expect(menu.querySelector('.comment-user-menu-trigger').getAttribute('aria-label'))
      .toBe("Open Agent One's profile menu")
    expect(menu.querySelector('.comment-presence-avatar').dataset.email).toBe('agent@example.com')
    expect(menu.querySelector('.comment-presence-avatar').dataset.userId).toBe('9')
    expect(menu.querySelector('.comment-user-popup-identity strong').textContent).toBe('Agent One')
    expect(menu.querySelector('.comment-user-popup-email').textContent).toBe('agent@example.com')
    expect(menu.querySelector('.comment-user-popup-status').classList.contains('is-online')).toBe(true)
    expect(menu.querySelector('[data-comment-user-menu-target="statusLabel"]').textContent).toBe('Online')
    expect(menu.querySelector('a.popup-menu-item').getAttribute('href')).toBe('/users/9')
    expect(menu.querySelector('button.popup-menu-item').textContent).toBe('Mention')
    expect(menu.querySelector('.comment-user-popup-guide')).toBeNull()
  })

  test('builds an offline draggable-agent menu with a default avatar and guide', () => {
    const menu = createUserMenu({
      user: { ...USER, email: null, default_avatar: true },
      online: false,
      labels: LABELS,
      menuId: 'participant-user-menu-9',
      draggable: true,
    })

    expect(menu.querySelectorAll('.avatar-initial')).toHaveLength(2)
    expect(menu.querySelector('.comment-user-popup-email').textContent).toBe('')
    expect(menu.querySelector('.comment-presence-avatar').classList.contains('inactive')).toBe(true)
    expect(menu.querySelector('.comment-user-popup-status').classList.contains('is-online')).toBe(false)
    expect(menu.querySelector('[data-comment-user-menu-target="statusLabel"]').textContent).toBe('Offline')
    expect(menu.querySelector('.comment-user-popup-guide').textContent).toBe(LABELS.dragGuide)
  })
})
