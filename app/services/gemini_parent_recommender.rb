class GeminiParentRecommender
  def initialize(client: GeminiClient.new)
    @client = client
  end

  def recommend(creative)
    user = creative.user

    # 1. Gather all potential category candidates
    # Candidates: All creatives user can write to + creative's current parent (even if not writable?)
    # Original logic: Distinct creatives having children + parent.
    # Note: Using `joins(:children)` filters only those that have children.

    categories = Creative
                   .joins(:children)
                   .distinct
                   .select { |c| c.has_permission?(user, :write) }

    parent = creative.parent
    if parent&.has_permission?(user, :write)
      categories << parent
    end
    categories = categories.uniq

    # 2. Build the tree structure for these categories
    # The formatter takes roots. To properly represent the hierarchy of these categories,
    # we should arguably format the entire accessible tree or at least a forest.
    # However, the user request says "Substitute logic ... when making the tree".
    # And providing context to Gemini.

    # Let's find the roots of these categories to present a coherent tree/forest.
    # Or simplified: just pass these categories as a list of roots?
    # If we pass random nodes as a list, they will look like roots in the formatter (level 0).
    # The original logic sent "id -> path string".
    # The new prompt expects a visual tree.
    # If we just dump scattered nodes as a list, it won't be a tree.

    # Better approach: Find the top-most ancestors of these categories that are also in the set?
    # Or just format them as a flat list if they are not connected?
    # The original logic constructed specific paths: "Grandparent > Parent > Self".

    # If I simply pass `categories` to `TreeFormatter`, it will print them all at level 0.
    # Unless I reconstruct a proper tree object or subset.

    # Wait, the user said: "PR Analysis ... replace {creative_tree} ... make tree like this".
    # For Category Recommendation, it probably implies the same "Context" format.
    # But `GeminiParentRecommender` logic was: send map of {id: path_string}.
    # The prompt generator in `GeminiClient` consumed this map.

    # So I need to:
    # 1. Update `GeminiParentRecommender` to generate the new STRING format representing the available categories.
    # 2. Update `GeminiClient` to accept this string instead of `categories` map.

    # The challenge: The `categories` array contains scattered nodes.
    # `TreeFormatter` prints a node and its children recursivley.
    # If I pass `categories` to `TreeFormatter`, it will print each category AND its children.
    # This might be too much info or duplicate info if children are also in `categories`.

    # Let's look at `GeminiParentRecommender` original logic again.
    # It iterated `categories`. For each, it built a path string: "Root > ... > Category".
    # And sent { id => path }.

    # If I want to present a TREE to Gemini, I should probably build a forest of the RELEVANT creatives.
    # If I just format `categories` as an array:
    # - {id: 1, ...} (and implementation prints children)
    # - {id: 2, ...}

    # If `categories` includes a parent and its child, `TreeFormatter` handling array of roots:
    # It just iterates and calls `format_node`.
    # `format_node` prints the node and recurses children.
    # So we might get duplicates if we are not careful.

    # Ideally, we should identity the Roots of the `categories` set.
    # But `categories` are "Creatives that have children" (potential parents).

    # Correct tree visualization for "All potential parents".
    # Maybe we should just format each candidate as a leaf in the list?
    # No, the user explicitly asked for indented tree.

    # Let's assume we want to show the hierarchy of `categories`.
    # We can try to "arrange" them into a tree structure.
    # Or simpler: The user might want us to use the specific FORMAT.
    # "Like: - {id: ..., desc: ...}"

    # Logic:
    # 1. Identify all `categories` (potential parents).
    # 2. We want to show them effectively.
    # The PROMPT in `GeminiClient` is: "Given the above categories (id, path)..."
    # It expected a list.

    # Proposal:
    # Just format each candidate as a top-level item?
    # " - {id: X, ... desc: "Root > Parent > Item"}"?
    # No, the user emphasized indentation for depth: "Structure the tree ... depth indentation".

    # So we should probably construct a real tree of the candidates.
    # `categories` is a list of nodes.
    # Let's find the effective roots among these categories.
    # And only include children if they are in `categories`?
    # `TreeFormatter` descends into ALL children.

    # Let's modify `GeminiParentRecommender` to:
    # 1. Identify the 'scope' of recommendation. (Likely the user's entire creative tree?)
    #    Original: `Creative.joins(:children)...` (Global search?)
    #    It seems to be all creatives the user can write to that have children.

    # If we print the entire tree of the user's writeable creatives, that would be the best context.
    # Let's try to get the Roots of all writeable creatives.

    roots = Creative.roots.select { |c| c.has_permission?(user, :write) }
    # This might be too many.

    # Let's stick to the current selection of `categories`, but simpler:
    # If we want to allow Gemini to pick ANY parent from the candidates.
    # We can present them in the tree structure.
    # To avoid duplication:
    # We can pass `categories` to a modified formatter or pre-process them.
    # But `TreeFormatter` as implemented takes a list of roots and prints their subtree.

    # Let's use `Creatives::TreeFormatter` but maybe we need to be careful about what we pass.
    # If we pass ALL `categories`, we get massive duplication and weirdness.

    # Hack for now:
    # The requirement is "Substitute logic in PR Analysis ... AND Category Recommendation".
    # PR Analysis passes `paths` which are constructed from the PR's affected files (or something).
    # Wait, `Github::PullRequestAnalyzer` `paths` argument is:
    # `paths: [ { path: "[1] Root > [2] Child", leaf: true } ]`
    # It's ALREADY a list of paths.
    # The user wants to changing how `{creative_tree}` is generated.
    # The user says: "When making the tree ... make it like this".

    # For `GeminiParentRecommender`:
    # It currently sends a list of paths.
    # I should change it to send a Tree view.
    # Construction:
    # Find all candidates.
    # Reconstruct the minimal tree that contains all candidates?

    # Simpler: Just get the `roots` of the `categories` set.
    # If `categories` contains A and B, and A is parent of B.
    # We should only pass A to the formatter?
    # The formatter will print A -> B -> ...
    # But `categories` logic filtered by "has children". B might not have children.
    # So B might not be in `categories` originally.
    # If B is not in `categories`, it won't be a candidate.

    # Okay, let's relax the "exact subset" constraint and just give Gemini
    # the "User's Creative Tree" (filtered by permissions).
    # This is much richer context.
    # `roots = Creative.roots.select { |c| c.has_permission?(user, :write) || c.has_permission?(user, :read) }`

    # Let's try to find roots specifically relevant to the `categories` we found.
    # `categories` = candidates.
    # We want to display them in a tree.

    # Let's filter `categories` to those that have NO parents within the `categories` set.
    # subset_ids = categories.map(&:id).to_set
    # virtual_roots = categories.select { |c| !subset_ids.include?(c.parent_id) }

    # Then we can use a "Filtered Tree Formatter" that only prints nodes in the set?
    # `TreeFormatter` format doesn't natively support filtering nodes.
    # But looking at `TreeFormatter` implementation: `node.children.each`.
    # It walks the REAL database children.

    # If I pass `virtual_roots` to `TreeFormatter`:
    # It will print VirtualRoot ... and ALL its DB children.
    # This adds more context (siblings maybe), which is probably GOOD for Gemini.

    # So change:
    # `categories` finding logic remains (these are the candidates).
    # BUT, for the PROMPT context, we want to show the tree.
    # We can show the tree of these candidates.
    # `virtual_roots = categories.select { |c| c.parent_id.nil? || !categories.include?(c.parent) }`
    # Pass `virtual_roots` to `TreeFormatter`.
    # `TreeFormatter` will print them and their children.
    # WE MUST ENSURE `TreeFormatter` logic `node.children` doesn't print things we don't want?
    # The `TreeFormatter` uses `node.children`. This returns sub-creatives.
    # If a child is NOT in `categories`, it gets printed too.
    # Is this okay?
    # "Category Recommendation" -> "recommend a parent".
    # If we show non-candidate leaf nodes, is that confusing?
    # "Which ids are the best parents...?"
    # If I show a leaf node (not in `categories` because it has no children), Gemini might pick it?
    # But if it has no children, maybe it's fine to become a parent (it becomes a branch).
    # Actually, `GeminiParentRecommender` filters `joins(:children)`.
    # Meaning it only recommends EXISTING parents.
    # This might be too restrictive?
    # Usually "Parent Recommendation" implies suggesting where to put a NEW creative.
    # Any existing creative can be a parent.
    # Why did the original code filter `joins(:children)`?
    # "categories = Creative.joins(:children)" -> existing branches.
    # Maybe it wanted to suggest "Existing Categories".

    # User's request doesn't say "Change the logic of WHAT is recommended".
    # It says "Change the logic of REcommending... and ... making the tree".
    # "Use the same logic (format) for PR Analysis".

    # I will assume the set of candidates (`categories`) is correct.
    # I just need to FORMAT them as this Tree structure.
    # If I use `TreeFormatter` on `virtual_roots` (roots within the set),
    # It will print descendants.
    # If I want to print ONLY the nodes in `categories`, I need to modify `TreeFormatter` or subclass it.

    # Let's MODIFY `TreeFormatter` (or add option) to filter nodes.
    # Or just let it print everything. Printing context is helpful.

    # Let's go with: "Find roots of the candidate set, print their full subtrees".
    # This might be massive if the tree is huge.
    # But usually manageable.

    # Let's update `recommend` to:
    # 1. Identify `categories` (candidates).
    # 2. Identify `roots` of these candidates for formatting representation.
    # 3. Use `TreeFormatter` to generate string.
    # 4. Pass string to `GeminiClient` (which needs update).

    valid_ids = categories.map(&:id).to_set
    # We want to represent the structural relationship of these valid_ids.
    # If we just dump them, we lose hierarchy.
    # We want to use the `TreeFormatter` format.

    # Let's refine `TreeFormatter` to accept a `filter_proc`?
    # Or just use it as is.

    # Decision:
    # Update `GeminiParentRecommender` to find `roots` of the passed `categories`.
    # Pass them to `TreeFormatter`.
    # Note: `TreeFormatter` by default follows `children`.
    # If `categories` is a sparse selection, `TreeFormatter` on `roots` might include extra nodes.
    # This is acceptable side-effect (better context).
    # Exception: If `roots` are very deep, we might miss context above?
    # No, `roots` are relative to the set.

    # Wait, `categories` might be disjoint.
    # Simple approach:
    # Use `TreeFormatter` on the `categories` treated as a list of roots?
    # No, that flattens them.

    # Let's find the "Forest" that covers `categories`.
    # `roots = categories.select { |c| !categories.any? { |other| other.id == c.parent_id } }`
    # Then `TreeFormatter.new.format(roots)`

    # Wait, if I do that, and `categories` excludes some middle node...
    # (A -> B -> C), `categories` = [A, C]. (B missing).
    # `roots` = [A, C]. (C's parent B is not in set).
    # Formatter(A) -> prints A -> B -> C (via database children).
    # Formatter(C) -> prints C.
    # We get C printed twice! Once under A, once as standalone.

    # Solution:
    # Pass `valid_ids` to `TreeFormatter` and tell it to ONLY print nodes in `valid_ids`.
    # If `valid_ids` is disjoint (A, C), we need to handle that.

    # Let's MODIFY `TreeFormatter` to support `allowed_ids`.
    # And `roots` calculation.

    # But for PR Analysis, we wanted to print the TREE.
    # The PR Analysis context usually comes from `paths` which is a LIST of paths.
    # "Root > Child".
    # We don't have `Creative` objects there natively?
    # Using `paths` hash: `[{path: "...", leaf: ...}]`.

    # Wait, `PullRequestAnalyzer`:
    # `@paths = normalize_paths(paths)`
    # It doesn't seem to have the IDs to look up `Creative` objects easily?
    # Ah, the `paths` seem to come from `PullRequestProcessor`.
    # `PullRequestProcessor` calculates `tree_entries`.
    # `path_exporter.full_paths_with_ids_and_progress_with_leaf`.
    # This returns entries like `"[1] Root > [2] Child"`.
    # It does NOT return `Creative` objects.

    # The user says: "Change logic for {creative_tree} ... make it like this".
    # And "PR Analysis ... substitute {creative_tree}".
    # Implies we have access to the tree data.

    # In `PullRequestAnalyzer`, we only have the `paths` strings.
    # We need to parse them or fetch the creatives?
    # Parsing the `paths` string to reconstruct the tree structure seems fragile but possible.
    # `"[1] Root > [2] Child"`
    # ID: 2, Parent: 1.

    # Alternative: Pass `Creative` objects to `PullRequestAnalyzer` instead of paths?
    # `PullRequestProcessor` has `creative` (the origin).
    # `analyzer = Github::PullRequestAnalyzer.new(..., creative: creative)`
    # The `creative` passed is the ROOT of the repo/link.
    # We can just format `creative` (and its subtree) using `TreeFormatter`!
    # Instead of relying on the `paths` argument for the tree visualization.
    # `paths` argument serves to highlight "FILES touched mapped to creatives"?
    # No, `PullRequestAnalyzer` `paths` argument comes from:
    # `tree_entries = path_exporter.full_paths_...`
    # This exports the ENTIRE tree?
    # `PathExporter` seems to export the whole tree.

    # If `paths` represents the whole tree, then we can definitely just use:
    # `TreeFormatter.new.format(@creative)` inside `PullRequestAnalyzer`.
    # Assuming `@creative` is the root context.

    # Let's verify `PullRequestProcessor`:
    # `creative = link.creative.effective_origin`
    # `path_exporter = Creatives::PathExporter.new(creative)`
    # `tree_entries = ...`
    # `analyzer = ... paths: tree_entries`

    # Yes, it seems `analyzer` has access to `@creative`.
    # So for `PullRequestAnalyzer`, we can IGNORE `@paths` for key `{creative_tree}` generation
    # and use `TreeFormatter.new.format(@creative)` directly.
    # This is much cleaner and robust.

    # Now back to `GeminiParentRecommender`.
    # It has `recommend(creative)`.
    # It finds `categories`.
    # Just use `TreeFormatter` on `categories` roots?
    # Or even better: `TreeFormatter` on `creative.user.creatives.roots`? (Context: All user's creatives).
    # `GeminiParentRecommender` filtered for "write" permission.

    # Let's try to pass the "Relevant Roots" to `TreeFormatter`.
    # `roots = categories.map { |c| c.effective_origin.root }.uniq` ?
    # Be careful with `effective_origin`.

    # Revised Plan for `GeminiParentRecommender`:
    # 1. Gather distinct roots of the `categories`.
    #    `roots = categories.map { |c| c.root }.uniq` (using closure_tree `root`)
    # 2. Use `TreeFormatter`.
    #    Note: This prints the WHOLE tree of those roots.
    #    This includes nodes NOT in `categories`.
    #    Is this okay?
    #    Actually current logic sends ONLY the paths of the categories.
    #    If we simply format the whole tree, it might be too large?
    #    User request: "recommendation button... recommends upper category... modify logic... substitute creative_tree... use same logic".

    # I'll stick to: `TreeFormatter` prints the subtree. I will pass the roots of the `categories`.
    # If the user has a massive tree, this might overflow context.
    # But `categories` logic was `Creative.joins(:children)...`.
    # This implies almost the whole tree anyway (branches).

    formatted_tree = Creatives::TreeFormatter.new.format(categories)
    # Be careful: `categories` is a list. Passing it to `format` treats them ALL as roots.
    # Result:
    # - Root
    #    - ...
    # - Child (if in categories)
    #    - ... (printed again)

    # I need to filter `categories` to only "Top-level items within the set".
    # `top_level = categories.reject { |c| categories.include?(c.parent) }`
    # `formatted_tree = Creatives::TreeFormatter.new.format(top_level)`
    # This prevents duplication.
    # And I will trust that `TreeFormatter` printing children (even those not in set) is acceptable/desired context.

    # Wait, if `categories` only contains "Creatives with children".
    # And I print children using `TreeFormatter` (which iterates `node.children`).
    # I will print "Leafs" (creatives without children).
    # Leaves are NOT in `categories`.
    # Is it bad to show leaves in the context for Parent Recommendation?
    # Probably not bad. It clarifies the tree.

    # So:
    # 1. Filter `categories` to `top_level` (roots within the set).
    # 2. Format `top_level`.

    top_level = categories.reject { |c| categories.any? { |other| other.id == c.parent_id } }
    tree_context = Creatives::TreeFormatter.new.format(top_level)

    ids = @client.recommend_parent_ids(tree_context, ActionController::Base.helpers.strip_tags(creative.description).to_s)
    # We still need to map back `ids` to paths?
    # The return value of `recommend` is `[{id: ..., path: ...}]`.
    # I need to reconstruct paths?
    # Or changes `GeminiClient` to return what we need.
    # `GeminiClient` returns IDs.
    # `GeminiParentRecommender` returns structure with `path`.
    # We can reconstruct paths for the returned IDs.

    # Let's start coding.

    top_level_categories = categories.reject { |c| categories.any? { |other| other.id == c.parent_id } }
    tree_text = Creatives::TreeFormatter.new.format(top_level_categories)

    ids = @client.recommend_parent_ids(tree_text,
                                       ActionController::Base.helpers.strip_tags(creative.description).to_s)

    # Reconstruct paths for result
    ids.map do |id|
       c = Creative.find_by(id: id)
       next unless c
       path = c.ancestors.reverse.map { |a| ActionController::Base.helpers.strip_tags(a.description) } + [ ActionController::Base.helpers.strip_tags(c.description) ]
       { id: id, path: path.join(" > ") }
    end.compact
  end
end
