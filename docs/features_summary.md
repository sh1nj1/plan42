# Features

## Creative Page

### Creative View
*   **Tree Structure**: Display creatives in a hierarchical tree.
*   **Progress Tracking**: Visualize progress with value ranges (0.0 - 1.0). Parent progress is calculated from children.
*   **Visual Boundaries**: Clear distinction of creative areas and child regions.
*   **Styles**: Auto-styling for top-level creatives (h1, h2, h3).

### Creative Page Menu
*   **New Creative**: Add creative with '+' button.
*   **Expand/Collapse All**: Toggle to expand or collapse all items.

### Creative Row Actions
*   **Navigation**: Click to zoom into creative (make it the root view).
*   **Move**: Drag and drop or move creative.
*   **Action Menu**: Specific row actions.
*   **Expand/Collapse**: Toggle child visibility.

### Creative Edit
*   **Inline Editing**: Edit text directly on the page.
*   **Rich Text**: Support for styling and formatting.

### Linked Creative
*   **Origin Linking**: A creative involves an origin_id can be placed in multiple locations.
*   **Navigation**: Link back to the origin creative.

### Filters
*   **Status Filter**: Filter by "Completed" or "Incomplete".
*   **Chat Filter**: Filter creatives with active chat messages.

### Search
*   Full-text search for creatives.

## Comment

### Chat & Messaging
*   **Real-time Messaging**: Comments behave like real-time chat messages.
*   **Chat Input**: Real-time typing indicators.
*   **User Status**: Online/offline status indicators.
*   **Participants**: Owner (host) and users with Feedback permission.
*   **Notifications**:
    *   Push notifications.
    *   Alerts when member+ users are offline.
*   **Read Receipts**: Avatars show who read messages (public comments only).
*   **Chat List**: Unified view of all topic messages.
*   **Topic Navigation**: Links to specific topics from the main chat view.
*   **New Message Badge**: 'New' badge on sidebar for topics with activity.
*   **Focus View**: View only messages for a specific topic.
*   **Multi-Role AI Chat**:
    *   AI Agent as a user.
    *   AI Chat: @gemini command for context-aware AI responses.

### Features
*   **Linked Creative Sync**: Comments synced with origin.
*   **Reactions**: Emoji reactions to messages.
*   **Activity Log**: System logs in chat.
*   **Permissions**: Granular control over chat access.

### Commands
*   **MCP Commands**: Execute MCP tools via slash commands.
*   **Dynamic Registration**: Auto-discovery of MCP tools.
*   **Result Rendering**: Visualize tool outputs in chat.
*   **Error Handling**: User-friendly error messages for failed commands.
*   **Conversion**: Convert comments to creatives or vice versa.

## Multi-User

### Sign up
*   **Email Verification**: Verify email address during sign up.
*   **Password Reset**: Reset forgotten passwords.

### Inbox
*   Notification center for messages and events.

### Share
*   **Share Popup**: Share creatives with specific permissions.
*   **User Search**: Auto-suggest users by name or email.
*   **User List**: View list of users with access.
*   **Permission Management**: Update permissions or remove users.

### User Settings
*   **Profile**: Manage user profile.
*   **Change Password**: Update current password.
*   **Avatar**: Manage user avatar.
*   **Theme**: Customize application theme (including Passkey support).
*   **OAuth Applications**: Manage connected OAuth apps.

## Tagging

### Tag System
*   **Grouping**: Tag creatives to group related items.

### Plan
*   **Plan Creation**: Create plans with target dates.
*   **Plan Linking**: Associate creatives with plans (inherits permissions).
*   **Progress Calculation**: Aggregated progress from linked creatives.
*   **Timeline**: Visual timeline view of plans.

### Tag Permission
*   Control visibility and management of tags.

## Integration

### Authentication & Servers
*   **OAuth**: Support for OAuth authentication.
*   **MCP Server**: Integration with Model Context Protocol servers.

### External Services
*   **Notion**: Integration for import/export or syncing.
*   **Google Calendar**: Integration for meeting scheduling.
*   **Github**:
    *   **Webhooks**: Handle GitHub events.
    *   **PR Analysis**: Automatic analysis of Pull Requests.
    *   **Popup**: GitHub integration interface.
    *   **Admin Control**: Configuration restricted to admins.

## Administration

### System
*   **System Settings**: Global configuration (e.g., Help URL).
*   **MCP Control**: Admin approval for new MCP tools.

### User Administration
*   **User Management**: List and manage registered users (Admin only).
*   **Deletion**: Permanently delete users and data (Admin only).
