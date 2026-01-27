# Model aliases for backward compatibility
# These allow using unprefixed class names (User, Creative, etc.)
# while the actual models live in the Collavre engine

Rails.application.config.to_prepare do
  # Services
  Object.const_set(:McpService, Collavre::McpService) unless Object.const_defined?(:McpService)
  Object.const_set(:AiAgentService, Collavre::AiAgentService) unless Object.const_defined?(:AiAgentService)
  Object.const_set(:AiClient, Collavre::AiClient) unless Object.const_defined?(:AiClient)
  Object.const_set(:AiSystemPromptRenderer, Collavre::AiSystemPromptRenderer) unless Object.const_defined?(:AiSystemPromptRenderer)
  Object.const_set(:GoogleCalendarService, Collavre::GoogleCalendarService) unless Object.const_defined?(:GoogleCalendarService)
  Object.const_set(:CommentLinkFormatter, Collavre::CommentLinkFormatter) unless Object.const_defined?(:CommentLinkFormatter)
  Object.const_set(:LinkPreviewFetcher, Collavre::LinkPreviewFetcher) unless Object.const_defined?(:LinkPreviewFetcher)
  Object.const_set(:MarkdownImporter, Collavre::MarkdownImporter) unless Object.const_defined?(:MarkdownImporter)
  Object.const_set(:AutoThemeGenerator, Collavre::AutoThemeGenerator) unless Object.const_defined?(:AutoThemeGenerator)
  Object.const_set(:GeminiParentRecommender, Collavre::GeminiParentRecommender) unless Object.const_defined?(:GeminiParentRecommender)
  Object.const_set(:PptImporter, Collavre::PptImporter) unless Object.const_defined?(:PptImporter)
  Object.const_set(:RubyLlmInteractionLogger, Collavre::RubyLlmInteractionLogger) unless Object.const_defined?(:RubyLlmInteractionLogger)
  Object.const_set(:NotionClient, Collavre::NotionClient) unless Object.const_defined?(:NotionClient)
  Object.const_set(:NotionService, Collavre::NotionService) unless Object.const_defined?(:NotionService)
  Object.const_set(:NotionCreativeExporter, Collavre::NotionCreativeExporter) unless Object.const_defined?(:NotionCreativeExporter)

  # Jobs
  Object.const_set(:AiAgentJob, Collavre::AiAgentJob) unless Object.const_defined?(:AiAgentJob)
  Object.const_set(:InboxSummaryJob, Collavre::InboxSummaryJob) unless Object.const_defined?(:InboxSummaryJob)
  Object.const_set(:NotionExportJob, Collavre::NotionExportJob) unless Object.const_defined?(:NotionExportJob)
  Object.const_set(:NotionSyncJob, Collavre::NotionSyncJob) unless Object.const_defined?(:NotionSyncJob)
  Object.const_set(:PermissionCacheCleanupJob, Collavre::PermissionCacheCleanupJob) unless Object.const_defined?(:PermissionCacheCleanupJob)
  Object.const_set(:PermissionCacheJob, Collavre::PermissionCacheJob) unless Object.const_defined?(:PermissionCacheJob)
  Object.const_set(:PushNotificationJob, Collavre::PushNotificationJob) unless Object.const_defined?(:PushNotificationJob)

  # Channels
  Object.const_set(:TopicsChannel, Collavre::TopicsChannel) unless Object.const_defined?(:TopicsChannel)
  Object.const_set(:CommentsPresenceChannel, Collavre::CommentsPresenceChannel) unless Object.const_defined?(:CommentsPresenceChannel)
  Object.const_set(:SlideViewChannel, Collavre::SlideViewChannel) unless Object.const_defined?(:SlideViewChannel)

  # Components
  Object.const_set(:AvatarComponent, Collavre::AvatarComponent) unless Object.const_defined?(:AvatarComponent)
  Object.const_set(:PlansTimelineComponent, Collavre::PlansTimelineComponent) unless Object.const_defined?(:PlansTimelineComponent)
  Object.const_set(:PopupMenuComponent, Collavre::PopupMenuComponent) unless Object.const_defined?(:PopupMenuComponent)
  Object.const_set(:ProgressFilterComponent, Collavre::ProgressFilterComponent) unless Object.const_defined?(:ProgressFilterComponent)
  Object.const_set(:UserMentionMenuComponent, Collavre::UserMentionMenuComponent) unless Object.const_defined?(:UserMentionMenuComponent)

  # Helpers
  Object.const_set(:CreativesHelper, Collavre::CreativesHelper) unless Object.const_defined?(:CreativesHelper)
  Object.const_set(:CommentsHelper, Collavre::CommentsHelper) unless Object.const_defined?(:CommentsHelper)
  Object.const_set(:NavigationHelper, Collavre::NavigationHelper) unless Object.const_defined?(:NavigationHelper)
  Object.const_set(:UserThemesHelper, Collavre::UserThemesHelper) unless Object.const_defined?(:UserThemesHelper)

  # Mailers
  Object.const_set(:InboxMailer, Collavre::InboxMailer) unless Object.const_defined?(:InboxMailer)
  Object.const_set(:InvitationMailer, Collavre::InvitationMailer) unless Object.const_defined?(:InvitationMailer)
  Object.const_set(:PasswordsMailer, Collavre::PasswordsMailer) unless Object.const_defined?(:PasswordsMailer)
  Object.const_set(:EmailVerificationMailer, Collavre::EmailVerificationMailer) unless Object.const_defined?(:EmailVerificationMailer)
  Object.const_set(:CreativeMailer, Collavre::CreativeMailer) unless Object.const_defined?(:CreativeMailer)

  # Service modules
  unless Object.const_defined?(:Creatives)
    Object.const_set(:Creatives, Module.new)
  end
  Creatives.const_set(:ProgressService, Collavre::Creatives::ProgressService) unless Creatives.const_defined?(:ProgressService)
  Creatives.const_set(:PermissionChecker, Collavre::Creatives::PermissionChecker) unless Creatives.const_defined?(:PermissionChecker)
  Creatives.const_set(:TreeFormatter, Collavre::Creatives::TreeFormatter) unless Creatives.const_defined?(:TreeFormatter)
  Creatives.const_set(:PlanTagger, Collavre::Creatives::PlanTagger) unless Creatives.const_defined?(:PlanTagger)
  Creatives.const_set(:IndexQuery, Collavre::Creatives::IndexQuery) unless Creatives.const_defined?(:IndexQuery)
  Creatives.const_set(:FilterPipeline, Collavre::Creatives::FilterPipeline) unless Creatives.const_defined?(:FilterPipeline)
  Creatives.const_set(:Reorderer, Collavre::Creatives::Reorderer) unless Creatives.const_defined?(:Reorderer)
  Creatives.const_set(:PermissionCacheBuilder, Collavre::Creatives::PermissionCacheBuilder) unless Creatives.const_defined?(:PermissionCacheBuilder)
  Creatives.const_set(:TreeBuilder, Collavre::Creatives::TreeBuilder) unless Creatives.const_defined?(:TreeBuilder)
  Creatives.const_set(:Importer, Collavre::Creatives::Importer) unless Creatives.const_defined?(:Importer)
  Creatives.const_set(:PathExporter, Collavre::Creatives::PathExporter) unless Creatives.const_defined?(:PathExporter)

  # Filters module
  unless Creatives.const_defined?(:Filters)
    Creatives.const_set(:Filters, Module.new)
  end
  Creatives::Filters.const_set(:BaseFilter, Collavre::Creatives::Filters::BaseFilter) unless Creatives::Filters.const_defined?(:BaseFilter)
  Creatives::Filters.const_set(:DateFilter, Collavre::Creatives::Filters::DateFilter) unless Creatives::Filters.const_defined?(:DateFilter)
  Creatives::Filters.const_set(:AssigneeFilter, Collavre::Creatives::Filters::AssigneeFilter) unless Creatives::Filters.const_defined?(:AssigneeFilter)
  Creatives::Filters.const_set(:TagFilter, Collavre::Creatives::Filters::TagFilter) unless Creatives::Filters.const_defined?(:TagFilter)
  Creatives::Filters.const_set(:CommentFilter, Collavre::Creatives::Filters::CommentFilter) unless Creatives::Filters.const_defined?(:CommentFilter)
  Creatives::Filters.const_set(:SearchFilter, Collavre::Creatives::Filters::SearchFilter) unless Creatives::Filters.const_defined?(:SearchFilter)
  Creatives::Filters.const_set(:ProgressFilter, Collavre::Creatives::Filters::ProgressFilter) unless Creatives::Filters.const_defined?(:ProgressFilter)

  # Comments module
  unless Object.const_defined?(:Comments)
    Object.const_set(:Comments, Module.new)
  end
  Comments.const_set(:CommandProcessor, Collavre::Comments::CommandProcessor) unless Comments.const_defined?(:CommandProcessor)
  Comments.const_set(:McpCommandBuilder, Collavre::Comments::McpCommandBuilder) unless Comments.const_defined?(:McpCommandBuilder)
  Comments.const_set(:ActionExecutor, Collavre::Comments::ActionExecutor) unless Comments.const_defined?(:ActionExecutor)
  Comments.const_set(:ActionValidator, Collavre::Comments::ActionValidator) unless Comments.const_defined?(:ActionValidator)
  Comments.const_set(:McpCommand, Collavre::Comments::McpCommand) unless Comments.const_defined?(:McpCommand)
  Comments.const_set(:CalendarCommand, Collavre::Comments::CalendarCommand) unless Comments.const_defined?(:CalendarCommand)

  # Github module
  unless Object.const_defined?(:Github)
    Object.const_set(:Github, Module.new)
  end
  Github.const_set(:PullRequestProcessor, Collavre::Github::PullRequestProcessor) unless Github.const_defined?(:PullRequestProcessor)
  Github.const_set(:WebhookProvisioner, Collavre::Github::WebhookProvisioner) unless Github.const_defined?(:WebhookProvisioner)
  Github.const_set(:Client, Collavre::Github::Client) unless Github.const_defined?(:Client)
  Github.const_set(:PullRequestAnalyzer, Collavre::Github::PullRequestAnalyzer) unless Github.const_defined?(:PullRequestAnalyzer)

  # SystemEvents module
  unless Object.const_defined?(:SystemEvents)
    Object.const_set(:SystemEvents, Module.new)
  end
  SystemEvents.const_set(:Router, Collavre::SystemEvents::Router) unless SystemEvents.const_defined?(:Router)
  SystemEvents.const_set(:ContextBuilder, Collavre::SystemEvents::ContextBuilder) unless SystemEvents.const_defined?(:ContextBuilder)
  SystemEvents.const_set(:Dispatcher, Collavre::SystemEvents::Dispatcher) unless SystemEvents.const_defined?(:Dispatcher)

  # Tools module - add aliases to existing gem module, don't create a new one
  # The rails_mcp_engine gem defines the Tools module, we just add our aliases to it
  if Object.const_defined?(:Tools)
    Tools.const_set(:CreativeRetrievalService, Collavre::Tools::CreativeRetrievalService) unless Tools.const_defined?(:CreativeRetrievalService)
  end

  # Inbox module (components)
  unless Object.const_defined?(:Inbox)
    Object.const_set(:Inbox, Module.new)
  end
  Inbox.const_set(:BadgeComponent, Collavre::Inbox::BadgeComponent) unless Inbox.const_defined?(:BadgeComponent)

  # Core models
  Object.const_set(:Current, Collavre::Current) unless Object.const_defined?(:Current)
  Object.const_set(:User, Collavre::User) unless Object.const_defined?(:User)
  Object.const_set(:Session, Collavre::Session) unless Object.const_defined?(:Session)
  Object.const_set(:Creative, Collavre::Creative) unless Object.const_defined?(:Creative)
  Object.const_set(:Comment, Collavre::Comment) unless Object.const_defined?(:Comment)
  Object.const_set(:CommentReaction, Collavre::CommentReaction) unless Object.const_defined?(:CommentReaction)
  Object.const_set(:CommentReadPointer, Collavre::CommentReadPointer) unless Object.const_defined?(:CommentReadPointer)
  Object.const_set(:CommentPresenceStore, Collavre::CommentPresenceStore) unless Object.const_defined?(:CommentPresenceStore)
  Object.const_set(:CreativeShare, Collavre::CreativeShare) unless Object.const_defined?(:CreativeShare)
  Object.const_set(:CreativeSharesCache, Collavre::CreativeSharesCache) unless Object.const_defined?(:CreativeSharesCache)
  Object.const_set(:CreativeExpandedState, Collavre::CreativeExpandedState) unless Object.const_defined?(:CreativeExpandedState)
  Object.const_set(:CreativeHierarchy, Collavre::CreativeHierarchy) unless Object.const_defined?(:CreativeHierarchy)
  Object.const_set(:Contact, Collavre::Contact) unless Object.const_defined?(:Contact)
  Object.const_set(:Device, Collavre::Device) unless Object.const_defined?(:Device)
  Object.const_set(:Email, Collavre::Email) unless Object.const_defined?(:Email)
  Object.const_set(:InboxItem, Collavre::InboxItem) unless Object.const_defined?(:InboxItem)
  Object.const_set(:Invitation, Collavre::Invitation) unless Object.const_defined?(:Invitation)
  Object.const_set(:Plan, Collavre::Plan) unless Object.const_defined?(:Plan)
  Object.const_set(:Topic, Collavre::Topic) unless Object.const_defined?(:Topic)
  Object.const_set(:Tag, Collavre::Tag) unless Object.const_defined?(:Tag)
  Object.const_set(:Label, Collavre::Label) unless Object.const_defined?(:Label)
  Object.const_set(:ActivityLog, Collavre::ActivityLog) unless Object.const_defined?(:ActivityLog)
  Object.const_set(:CalendarEvent, Collavre::CalendarEvent) unless Object.const_defined?(:CalendarEvent)
  Object.const_set(:SystemSetting, Collavre::SystemSetting) unless Object.const_defined?(:SystemSetting)
  Object.const_set(:UserTheme, Collavre::UserTheme) unless Object.const_defined?(:UserTheme)
  Object.const_set(:Task, Collavre::Task) unless Object.const_defined?(:Task)
  Object.const_set(:TaskAction, Collavre::TaskAction) unless Object.const_defined?(:TaskAction)
  Object.const_set(:McpTool, Collavre::McpTool) unless Object.const_defined?(:McpTool)
  Object.const_set(:GithubAccount, Collavre::GithubAccount) unless Object.const_defined?(:GithubAccount)
  Object.const_set(:GithubRepositoryLink, Collavre::GithubRepositoryLink) unless Object.const_defined?(:GithubRepositoryLink)
  Object.const_set(:NotionAccount, Collavre::NotionAccount) unless Object.const_defined?(:NotionAccount)
  Object.const_set(:NotionPageLink, Collavre::NotionPageLink) unless Object.const_defined?(:NotionPageLink)
  Object.const_set(:NotionBlockLink, Collavre::NotionBlockLink) unless Object.const_defined?(:NotionBlockLink)
  Object.const_set(:WebauthnCredential, Collavre::WebauthnCredential) unless Object.const_defined?(:WebauthnCredential)
end
