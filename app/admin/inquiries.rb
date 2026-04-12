# frozen_string_literal: true

ActiveAdmin.register Inquiry do
  menu label: 'Заявки', priority: 4

  permit_params :name, :email, :phone, :message, :status, :property_id, :user_id

  actions :index, :show, :destroy

  index do
    selectable_column
    id_column
    column :name
    column :email
    column :phone
    column('Объявление') { |i| link_to i.property&.title, admin_property_path(i.property) if i.property }
    column('Статус')     { |i| i.status }
    column :created_at
    actions
  end

  filter :name
  filter :email
  filter :phone
  filter :status, as: :select, collection: Inquiry.statuses
  filter :created_at

  show do
    attributes_table do
      row :id
      row :name
      row :email
      row :phone
      row :message
      row('Статус')     { |i| i.status }
      row('Объявление') { |i| link_to i.property&.title, admin_property_path(i.property) if i.property }
      row :user
      row :created_at
    end
  end
end
