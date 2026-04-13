# frozen_string_literal: true

class AddPreferredIndexersToDownloadClients < ActiveRecord::Migration[8.1]
  def change
    add_column :download_clients, :preferred_indexers, :string
  end
end
