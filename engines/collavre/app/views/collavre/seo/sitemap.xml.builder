xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.urlset xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9" do
  @creatives.each do |creative|
    xml.url do
      xml.loc public_creative_url(public_id: creative.public_id, slug: creative.public_slug.presence)
    end
  end
end
