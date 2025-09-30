class AddIndexesToTagsTable < ActiveRecord::Migration[7.0]
  def change
    # 복합 인덱스 추가 - 태그된 크리에이티브 조회 성능 향상
    add_index :tags, [:creative_id, :label_id], unique: true, name: 'index_tags_on_creative_id_and_label_id' unless index_exists?(:tags, [:creative_id, :label_id])
    add_index :tags, :label_id, name: 'index_tags_on_label_id' unless index_exists?(:tags, :label_id)
    add_index :tags, :creative_id, name: 'index_tags_on_creative_id' unless index_exists?(:tags, :creative_id)
  end
end
