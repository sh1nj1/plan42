# Features

## List Creatives

### Creative View

#### A Creative should be ordered by sequence


#### Show creative boundaries

* Highlight each individual creative.
  * Change the creative's background color on hover to make its area clear.
  * On mobile, add a tall leading border block so items remain distinguishable without hover.
* Indicate the extent of child regions.
  * When a creative supports the expansion action, show where its subtree begins and ends.

#### View count


#### Progress

* Value range 0.0 \~ 1.0
* Recalculate parent progress whenever the page is filtered. For example, if only creatives tagged to a Plan are visible, compute progress from that subset alone.
* Provide flexible calculation methods.
  * Default to averaging the progress values of child creatives.
  * Consider weighted formulas to account for task size, difficulty, or other relevant factors.
* Parent Creative progress should be auto\-calculated by it's children progress
* Only leaf Creative progress can be edited by a user

#### Creative Level Style

* Top 3 parent level Creative will be represented as h1, h2, h3
* Leaf Creative should not be applied auto\-level style

#### Printable Page

* When printing the app from a browser, omit menus, popups, and other chrome so only the content is printed.

#### Conversion

* Idea- or R&amp;D-level work often requires exploration, research, and discussion before it belongs in the main document. Capture those conversations as comments on the related creative, then convert them into official creatives once the work is finalized.
* Allow a comment to be converted into a child creative.
* Allow a creative to be converted into a comment on its parent.
* Converting outdated or unnecessary items into comments helps keep the primary document focused.
* Define how backlog items should be handled.

#### Creatives should contain its tree structure even if some of the Creatives hidden by filters or permissions


#### List all tags for the creative and toggle button to filter with that tag


#### Expand-all toggle


#### Text Styles

* Center-align paragraphs
* Right-align paragraphs


### Actions

#### Drag and Drop Creative to change parent or order

* Drop to up or down and show indicationChange parent if not same parent.
* Drop to be appended as child Creative if a user drop to the right side of the creative rowShow child drop indication \- do not show up/down line indication and "↳" arrow like indication

#### Row Action Buttons

* Only show action buttons when user over the creative row to look UI clean
* New Creative
  * Form
    * Allow linking to other creatives.
    * The cancel action should restore the previous state.
  * When adding while a tag filter is active, apply all of those tags to the new creative.
* Always show row action buttons when it is mobile device

#### Creative menu

* Add&nbsp; Creative
  * New sub-creative
  * Add below — insert a sibling beneath the current creative
  * New upper-creative
* Import
  * Import from Markdown file.
    * Convert markdown table
    * Covert link
  * When importing set parent_id as current creative and import everything under the current Creative.
* Deletion
  * Delete one Creative onlyWhen deleting a Creative, all its children should be re\-linked to its parent \(i.e., their parent_id set to the deleted Creative’s parent\).After deletion, redirect to the parent Creative \(or to the root if there is no parent\).
  * Delete with children
* Export
  * Markdown
  * Export to Notion page

#### Expansion toggle

* Expansion toggle for each Creative on the left side
* Keep expansion state at given Creative for each User

#### Add child creative button on left side


#### Link to Creative show it's children and Creative actions


#### Multi\-Selection

* In selection mode, disable the usual drag-and-drop reordering. Dragging with the Shift key should add items to the selection, and dragging with the Alt key should remove them.

#### Attach files

* Use the Lexical editor's attachment pipeline (replaces the old Trix integration)


### Inline edit a Creative

#### Change text


#### In edit mode, allow navigating to the previous or next creative


#### In edit mode, allow adding a new creative directly below


#### In edit mode, allow adding a new child creative


#### Provide a cancel button to discard changes


#### Pressing Enter switches to edit mode


#### Change progress



### Filters

#### Show only completed Creatives


#### Show only incomplete Creatives


#### Filter creatives added within a specific time range


#### Filter by selected tags


#### Filter to creatives that have comments


#### Filter to creatives with no tags


#### Show Creatives only given level depth




## Commenting

### Allow adding, deleting, and listing comments on a creative.


### Only the owner can edit or delete a comment


### For a Linked Creative, store comments on the origin and display the origin's comment thread


### Topic

#### Comments support a two-level hierarchy.


#### Display the comment list under each topic.


#### Maintain the Creative &gt; Topic &gt; Comment relationship.


#### Treat a topic as a hidden creative.



### Comment list

#### Comment filters should target only the selected creative's descendants.


#### Provide a filter that shows only creatives with comments.



### Chat

#### Individual comments should behave like chat messages with real-time delivery.


#### When mentioning a user without access, prompt to share the creative with Feedback permission.


#### If a new comment arrives on the current screen, show a notice such as "A new comment was added. Go to comment." Include a link that opens the comment pane, highlights the comment, and clears the notice after it is used.


#### Display user online status.


#### Chat participants include the creative owner as the host and every user with Feedback permission.


#### AI agents

* When a user enables an AI agent, it should chat like a teammate.


### Chat \(Comment\) Commands

#### Allow generating a creative from the current thread, similar to [Conversion](https://plan42.vrerv.com/creatives/430).


#### Offline meetings

* Typing "/meeting " opens a dialog to schedule a meeting with all current participants; integrate with Google Calendar.


### Allow editing comments.


### Allow mentioning users in comments.



## UI/UX

### Navigation


### Customise 404


### Favicon


### Tips

#### In selection mode, display the message "You can drag to toggle selection" above the page title, add a close button, and store whether the user dismissed it in UserLearned.



### Theme

#### Provide a default theme.


#### Themes define creative level styles and completed vs. incomplete styling.


#### Dark Mode UI




## Multi\-User

### Sign up

#### Email verification


#### Reset Password


#### Tutorial

* Show a tutorial when a user logs in for the first time.
* Tutorial content
  * Create a six-level document that introduces the Collavre product so the tutorial itself is composed of creatives.
* Collavre tutorial
  * Collavre is an integrated collaboration platform for documents, tasks, and chat.
  * Key concepts: unified tree and document/creative pages, completion percentages that roll up as averages, tags for plans and sharing, real-time discussion via comments, and role-based multi-assignment for planning, design, and development.


### On\-Premises


### Organisation

#### A creative can be owned by the organisation, and all descendants inherit organisation ownership.



### Inbox

#### Inbox Item List

* Display messages and events delivered to the user in the Inbox.
* Inbox messages have "new" and "read" states.
* Add an "Inbox" menu item that opens a right-hand slide-out panel listing messages.
* Default the Inbox list to unread messages.
* Provide a close control to dismiss the slide-out.
* Include a "show unread messages" toggle in the Inbox list.

#### Notify Inbox Message

* At 09:00 every day, email up to ten unread Inbox messages per user; skip the email if there are no unread items.

#### Inbox Message

* When a user leaves a comment, add an InboxItem for the creative owner with a message such as "{User.email} added "{comment}"."
* Expose comment URLs in the form /creatives/:creative_id/comments/:comment_id; opening the link should display the comment popup and flash-highlight the comment.
* When a creative is shared, create an Inbox message for the recipient such as "{user} shared "{short_title}"." Clicking it should open /creatives/:id.
* Mark an Inbox message as read automatically when the user follows its link.


### User Avatar

#### Display avatars alongside user links. Clicking an avatar should open a menu (Profile, Log out) instead of navigating immediately. Add avatar management to the profile, use a placeholder when no avatar is set, and allow external avatar URLs.



### Change password


### Share

#### Share a Creative to a user with permission


#### Invitation

* Invitation for by sharing, if the user not exists
* Users can view the invitation list and check the status of each invite.

#### List shared users


#### Only given Creatives are shown for each User by their permission.


#### Update share user's permission


#### Delete shared user


#### Permissions

* No access permission
* Read permission
* Feedback permission \- can comment
* Write permission
* Full access permission
* Permissions apply to every descendant node.
* Add a NONE permission override to exclude a specific child node.



## Search

### Simple word matching


### Show a "no results" message when a search fails


### Include creatives whose relevant information lives in comments


### Advanced filtering and sorting (ransack)


### Fast search for large datasets

#### searchkick (Elasticsearch-based)


#### meilisearch-rails (quick to install and simple to configure)



### Place the search box in the app header and allow text input.



## Tagging

### Tag Creatives to list only given Creatives


### Tag Permission

#### List owner tags or owner is nil


#### Owner can delete



### Variation

#### same contents but different expression. e.g. translations



### Plan

#### User must set target date and set name optionally


#### Total progress for Plan


#### Allow users to rename a Plan


#### Plan Timeline

* The plan bar should fill according to the completion percentage and always display the name and percentage when present.
* Show the plan bar between the plan's creation and target dates, updating it as the visible date range scrolls.
* Render the plan timeline as a horizontal calendar with infinite scrolling in both directions to reveal additional dates.



## Integration

### Notion


### Slack


### Jira


### Github


### Gitlab


### OpenAI Codex CLI or Cloud



## BI

### Automate weekly reporting



## Developer features

### List users \- [link](https://plan42.vrerv.com/users)


### List all emails \- sent by the system for verification



## Directory Tree

### Show directory tree on the left side panel



## Linked Creative

### A creative with an origin_id is a Linked Creative.


### Linked creatives display a link to their origin so users can jump back to the source.



