class CreateDummyTrilogyRecord < ActiveRecord::Migration[6.1]
  def change
    create_table :dummy_trilogy_records do |t|
      t.string :name
      t.string :unique_name
      t.datetime :created_at, precision: 6, null: false
    end
    add_index :dummy_trilogy_records, :unique_name, unique: true
  end
end
