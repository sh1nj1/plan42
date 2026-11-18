module Collavre
  # Persist rendered slides using the same renderer as attachment previews.
  class PptImporter < PptRenderer
    MAX_SLIDES = PptRenderer::MAX_SLIDES
    MAX_ENTRIES = PptRenderer::MAX_ENTRIES
    MAX_ENTRY_BYTES = PptRenderer::MAX_ENTRY_BYTES
    MAX_RENDERED_BYTES = PptRenderer::MAX_RENDERED_BYTES
    MAX_TOTAL_BYTES = PptRenderer::MAX_TOTAL_BYTES
    def self.import(file, parent:, user:, create_root: false, filename: nil)
      new(file, parent: parent, user: user, create_root: create_root, filename: filename).import
    end

    def initialize(file, parent:, user:, create_root:, filename:)
      super(file)
      @parent = parent
      @user = user
      @create_root = create_root
      @filename = filename
    end

    def import
      created = []
      Creative.transaction(requires_new: true) do |transaction|
        transaction.after_rollback { @blob_cache.each_value(&:delete) }
        descriptions = render
        root = create_import_root(created)
        sequence = next_sequence(root)
        descriptions.each_with_index do |description, index|
          created << Creative.create!(user: @user, parent: root, description: description, sequence: sequence + index)
        end
      end
      Creative::RealtimeBroadcastable.broadcast_batch_created(created)
      created
    end

    private

    def create_import_root(created)
      return @parent unless @create_root

      title = @filename ? File.basename(@filename, File.extname(@filename)) : "Presentation"
      root = Creative.create!(
        user: @user,
        parent: @parent,
        description: ERB::Util.html_escape(title),
        sequence: next_sequence(@parent)
      )
      created << root
      root
    end

    def next_sequence(parent)
      siblings = parent ? parent.children : Creative.roots
      (siblings.maximum(:sequence) || -1) + 1
    end
  end
end
