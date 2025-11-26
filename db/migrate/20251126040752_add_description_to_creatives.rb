class AddDescriptionToCreatives < ActiveRecord::Migration[8.1]
  def up
    add_column :creatives, :description, :text, limit: 4294967295

    # Data Migration
    say_with_time "Migrating ActionText to description column" do
      Creative.reset_column_information
      Creative.find_each do |creative|
        rich_text = ActionText::RichText.find_by(record_type: "Creative", record_id: creative.id, name: "description")
        if rich_text
          new_description = convert_action_text_content(rich_text.body.to_html)
          creative.update_column(:description, new_description)
        end
      end
    end
  end

  def down
    remove_column :creatives, :description
  end

  private

  def convert_action_text_content(html)
    return "" if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    doc.css("action-text-attachment").each do |node|
      sgid = node["sgid"]
      content_type = node["content-type"]
      url = node["url"]
      filename = node["filename"]
      width = node["width"]
      height = node["height"]
      caption = node["caption"]

      blob = nil
      begin
        blob = ActionText::Attachable.from_attachable_sgid(sgid)
      rescue => e
        puts "Error locating blob for sgid #{sgid}: #{e.message}"
      end

      if blob
        url = Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
        filename = blob.filename.to_s
        content_type = blob.content_type
      end

      if url.present?
        if content_type&.start_with?("image/")
          img = Nokogiri::XML::Node.new("img", doc)
          img["src"] = url
          img["alt"] = caption || filename
          img["width"] = width if width
          img["height"] = height if height
          node.replace(img)
        else
          a = Nokogiri::XML::Node.new("a", doc)
          a["href"] = url
          a["target"] = "_blank"
          a.content = caption || filename || "Attachment"
          node.replace(a)
        end
      else
        # If no URL found, keep the original node or maybe remove it?
        # Keeping it might be safer but it won't render.
        # Let's leave it as is if we can't transform it.
      end
    end

    doc.to_html
  end
end
