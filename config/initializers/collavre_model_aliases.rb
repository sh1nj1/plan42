# Model aliases for backward compatibility
# These allow using unprefixed class names (User, Creative, etc.)
# while the actual models live in the Collavre engine

# Helper to set or replace a constant alias
# Uses remove_const + const_set to handle code reloading properly
def set_alias(mod, name, target)
  mod.send(:remove_const, name) if mod.const_defined?(name, false)
  mod.const_set(name, target)
end

Rails.application.config.to_prepare do
  # Services
  set_alias(Object, :McpService, Collavre::McpService)
  set_alias(Object, :AiAgentService, Collavre::AiAgentService)
  set_alias(Object, :AiClient, Collavre::AiClient)
  set_alias(Object, :AiSystemPromptRenderer, Collavre::AiSystemPromptRenderer)
  set_alias(Object, :GoogleCalendarService, Collavre::GoogleCalendarService)
  set_alias(Object, :CommentLinkFormatter, Collavre::CommentLinkFormatter)
  set_alias(Object, :LinkPreviewFetcher, Collavre::LinkPreviewFetcher)
  set_alias(Object, :MarkdownImporter, Collavre::MarkdownImporter)
  set_alias(Object, :AutoThemeGenerator, Collavre::AutoThemeGenerator)
  set_alias(Object, :GeminiParentRecommender, Collavre::GeminiParentRecommender)
  set_alias(Object, :PptImporter, Collavre::PptImporter)
  set_alias(Object, :RubyLlmInteractionLogger, Collavre::RubyLlmInteractionLogger)
  set_alias(Object, :NotionClient, Collavre::NotionClient)
  set_alias(Object, :NotionService, Collavre::NotionService)
  set_alias(Object, :NotionCreativeExporter, Collavre::NotionCreativeExporter)

  # Jobs
  set_alias(Object, :AiAgentJob, Collavre::AiAgentJob)
  set_alias(Object, :InboxSummaryJob, Collavre::InboxSummaryJob)
  set_alias(Object, :NotionExportJob, Collavre::NotionExportJob)
  set_alias(Object, :NotionSyncJob, Collavre::NotionSyncJob)
  set_alias(Object, :PermissionCacheCleanupJob, Collavre::PermissionCacheCleanupJob)
  set_alias(Object, :PermissionCacheJob, Collavre::PermissionCacheJob)
  set_alias(Object, :PushNotificationJob, Collavre::PushNotificationJob)

  # Channels
  set_alias(Object, :TopicsChannel, Collavre::TopicsChannel)
  set_alias(Object, :CommentsPresenceChannel, Collavre::CommentsPresenceChannel)
  set_alias(Object, :SlideViewChannel, Collavre::SlideViewChannel)

  # Components
  set_alias(Object, :AvatarComponent, Collavre::AvatarComponent)
  set_alias(Object, :PlansTimelineComponent, Collavre::PlansTimelineComponent)
  set_alias(Object, :PopupMenuComponent, Collavre::PopupMenuComponent)
  set_alias(Object, :ProgressFilterComponent, Collavre::ProgressFilterComponent)
  set_alias(Object, :UserMentionMenuComponent, Collavre::UserMentionMenuComponent)

  # Helpers
  set_alias(Object, :CreativesHelper, Collavre::CreativesHelper)
  set_alias(Object, :CommentsHelper, Collavre::CommentsHelper)
  set_alias(Object, :NavigationHelper, Collavre::NavigationHelper)
  set_alias(Object, :UserThemesHelper, Collavre::UserThemesHelper)

  # Mailers
  set_alias(Object, :InboxMailer, Collavre::InboxMailer)
  set_alias(Object, :InvitationMailer, Collavre::InvitationMailer)
  set_alias(Object, :PasswordsMailer, Collavre::PasswordsMailer)
  set_alias(Object, :EmailVerificationMailer, Collavre::EmailVerificationMailer)
  set_alias(Object, :CreativeMailer, Collavre::CreativeMailer)

  # Service modules - ensure module exists first
  Object.const_set(:Creatives, Module.new) unless Object.const_defined?(:Creatives, false)
  set_alias(Creatives, :ProgressService, Collavre::Creatives::ProgressService)
  set_alias(Creatives, :PermissionChecker, Collavre::Creatives::PermissionChecker)
  set_alias(Creatives, :TreeFormatter, Collavre::Creatives::TreeFormatter)
  set_alias(Creatives, :PlanTagger, Collavre::Creatives::PlanTagger)
  set_alias(Creatives, :IndexQuery, Collavre::Creatives::IndexQuery)
  set_alias(Creatives, :FilterPipeline, Collavre::Creatives::FilterPipeline)
  set_alias(Creatives, :Reorderer, Collavre::Creatives::Reorderer)
  set_alias(Creatives, :PermissionCacheBuilder, Collavre::Creatives::PermissionCacheBuilder)
  set_alias(Creatives, :TreeBuilder, Collavre::Creatives::TreeBuilder)
  set_alias(Creatives, :Importer, Collavre::Creatives::Importer)
  set_alias(Creatives, :PathExporter, Collavre::Creatives::PathExporter)

  # Filters module
  Creatives.const_set(:Filters, Module.new) unless Creatives.const_defined?(:Filters, false)
  set_alias(Creatives::Filters, :BaseFilter, Collavre::Creatives::Filters::BaseFilter)
  set_alias(Creatives::Filters, :DateFilter, Collavre::Creatives::Filters::DateFilter)
  set_alias(Creatives::Filters, :AssigneeFilter, Collavre::Creatives::Filters::AssigneeFilter)
  set_alias(Creatives::Filters, :TagFilter, Collavre::Creatives::Filters::TagFilter)
  set_alias(Creatives::Filters, :CommentFilter, Collavre::Creatives::Filters::CommentFilter)
  set_alias(Creatives::Filters, :SearchFilter, Collavre::Creatives::Filters::SearchFilter)
  set_alias(Creatives::Filters, :ProgressFilter, Collavre::Creatives::Filters::ProgressFilter)

  # Comments module
  Object.const_set(:Comments, Module.new) unless Object.const_defined?(:Comments, false)
  set_alias(Comments, :CommandProcessor, Collavre::Comments::CommandProcessor)
  set_alias(Comments, :McpCommandBuilder, Collavre::Comments::McpCommandBuilder)
  set_alias(Comments, :ActionExecutor, Collavre::Comments::ActionExecutor)
  set_alias(Comments, :ActionValidator, Collavre::Comments::ActionValidator)
  set_alias(Comments, :McpCommand, Collavre::Comments::McpCommand)
  set_alias(Comments, :CalendarCommand, Collavre::Comments::CalendarCommand)

  # Github module
  Object.const_set(:Github, Module.new) unless Object.const_defined?(:Github, false)
  set_alias(Github, :PullRequestProcessor, Collavre::Github::PullRequestProcessor)
  set_alias(Github, :WebhookProvisioner, Collavre::Github::WebhookProvisioner)
  set_alias(Github, :Client, Collavre::Github::Client)
  set_alias(Github, :PullRequestAnalyzer, Collavre::Github::PullRequestAnalyzer)

  # SystemEvents module
  Object.const_set(:SystemEvents, Module.new) unless Object.const_defined?(:SystemEvents, false)
  set_alias(SystemEvents, :Router, Collavre::SystemEvents::Router)
  set_alias(SystemEvents, :ContextBuilder, Collavre::SystemEvents::ContextBuilder)
  set_alias(SystemEvents, :Dispatcher, Collavre::SystemEvents::Dispatcher)

  # Inbox module (components)
  Object.const_set(:Inbox, Module.new) unless Object.const_defined?(:Inbox, false)
  set_alias(Inbox, :BadgeComponent, Collavre::Inbox::BadgeComponent)

  # Core models
  set_alias(Object, :Current, Collavre::Current)
  set_alias(Object, :User, Collavre::User)
  set_alias(Object, :Session, Collavre::Session)
  set_alias(Object, :Creative, Collavre::Creative)
  set_alias(Object, :Comment, Collavre::Comment)
  set_alias(Object, :CommentReaction, Collavre::CommentReaction)
  set_alias(Object, :CommentReadPointer, Collavre::CommentReadPointer)
  set_alias(Object, :CommentPresenceStore, Collavre::CommentPresenceStore)
  set_alias(Object, :CreativeShare, Collavre::CreativeShare)
  set_alias(Object, :CreativeSharesCache, Collavre::CreativeSharesCache)
  set_alias(Object, :CreativeExpandedState, Collavre::CreativeExpandedState)
  set_alias(Object, :CreativeHierarchy, Collavre::CreativeHierarchy)
  set_alias(Object, :Contact, Collavre::Contact)
  set_alias(Object, :Device, Collavre::Device)
  set_alias(Object, :Email, Collavre::Email)
  set_alias(Object, :InboxItem, Collavre::InboxItem)
  set_alias(Object, :Invitation, Collavre::Invitation)
  set_alias(Object, :Plan, Collavre::Plan)
  set_alias(Object, :Topic, Collavre::Topic)
  set_alias(Object, :Tag, Collavre::Tag)
  set_alias(Object, :Label, Collavre::Label)
  set_alias(Object, :ActivityLog, Collavre::ActivityLog)
  set_alias(Object, :CalendarEvent, Collavre::CalendarEvent)
  set_alias(Object, :SystemSetting, Collavre::SystemSetting)
  set_alias(Object, :UserTheme, Collavre::UserTheme)
  set_alias(Object, :Task, Collavre::Task)
  set_alias(Object, :TaskAction, Collavre::TaskAction)
  set_alias(Object, :McpTool, Collavre::McpTool)
  set_alias(Object, :GithubAccount, Collavre::GithubAccount)
  set_alias(Object, :GithubRepositoryLink, Collavre::GithubRepositoryLink)
  set_alias(Object, :NotionAccount, Collavre::NotionAccount)
  set_alias(Object, :NotionPageLink, Collavre::NotionPageLink)
  set_alias(Object, :NotionBlockLink, Collavre::NotionBlockLink)
  set_alias(Object, :WebauthnCredential, Collavre::WebauthnCredential)
end

# Tools module alias - handled after initialization to ensure rails_mcp_engine has loaded
# This runs after all gems and initializers are fully loaded
Rails.application.config.after_initialize do
  if Object.const_defined?(:Tools)
    Tools.send(:remove_const, :CreativeRetrievalService) if Tools.const_defined?(:CreativeRetrievalService, false)
    Tools.const_set(:CreativeRetrievalService, Collavre::Tools::CreativeRetrievalService)
  end
end
