# Collavre Documentation

## Guides

- [Installation Guide](installation.md) - How to install and configure Collavre in your Rails app

## Overview

Collavre is a Rails engine that provides:

- **Knowledge Management** - Tree-structured documents and notes
- **Task Management** - Hierarchical task lists with progress tracking
- **Real-time Chat** - Comments and discussions within any item
- **AI Integration** - LLM-powered agents for collaboration

## Architecture

### Core Models

| Model | Description |
|-------|-------------|
| `Creative` | Tree container for work items, documents, and discussions |
| `User` | System user with optional AI agent capabilities |
| `Comment` | Real-time chat messages within creatives |
| `Topic` | Conversation namespace within a creative |
| `CreativeShare` | Permission grants for sharing |

### JavaScript Structure

```
app/javascript/
├── collavre.js              # Main entry point
├── controllers/             # Stimulus controllers
├── components/              # UI components (React/Lit)
├── modules/                 # Feature modules
├── lib/                     # Utilities and helpers
├── services/                # ActionCable and API services
└── utils/                   # Common utilities
```

### Stylesheet Structure

```
app/assets/stylesheets/collavre/
├── creatives.css            # Main creative tree styles
├── comments_popup.css       # Comment panel styles
├── dark_mode.css            # Dark theme
├── mention_menu.css         # @mention dropdown
├── popup.css                # Common popup styles
├── slide_view.css           # Presentation mode
└── ...
```

## Development

### Building the Gem

```bash
cd engines/collavre
gem build collavre.gemspec
```

### Running Tests

```bash
# From the host app root
rails test engines/collavre/test

# Exclude collavre from host app tests
rake test E=collavre
```

### Watch Mode for Assets

```bash
npm run build -- --watch
```
