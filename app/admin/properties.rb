# frozen_string_literal: true

ActiveAdmin.register Property do
  menu label: 'Объявления', priority: 3

  permit_params :title, :description, :price, :deal_type, :status,
                :area, :rooms, :floor, :total_floors, :address,
                :district, :city, :condition, :user_id

  scope :all, default: true
  scope('На проверке') { |s| s.where(status: :pending) }
  scope('Активные')    { |s| s.where(status: :active) }
  scope('Архив')       { |s| s.where(status: :archived) }

  index do
    selectable_column
    id_column
    column :title
    column('Тип сделки') { |p| p.deal_type }
    column('Статус')     { |p| p.status }
    column :price do |p|
      p.price_formatted
    end
    column :user
    column :created_at
    actions
  end

  filter :title
  filter :deal_type, as: :select, collection: Property.deal_types
  filter :status,    as: :select, collection: Property.statuses
  filter :city
  filter :district
  filter :price_gteq, label: 'Цена от'
  filter :price_lteq, label: 'Цена до'
  filter :created_at

  show do
    attributes_table do
      row :id
      row :title
      row :description
      row('Тип сделки') { |p| p.deal_type }
      row('Статус')     { |p| p.status }
      row :price
      row :area
      row :rooms
      row :floor
      row :total_floors
      row :address
      row :district
      row :city
      row :user
      row :created_at
      row :updated_at
    end
  end

  form do |f|
    f.inputs 'Объявление' do
      f.input :title, label: 'Заголовок'
      f.input :description, label: 'Описание'
      f.input :deal_type, as: :select, collection: Property.deal_types.keys, label: 'Тип сделки'
      f.input :status, as: :select, collection: Property.statuses.keys, label: 'Статус'
      f.input :price, label: 'Цена'
      f.input :area, label: 'Площадь'
      f.input :rooms, label: 'Комнаты'
      f.input :floor, label: 'Этаж'
      f.input :total_floors, label: 'Всего этажей'
      f.input :address, label: 'Адрес'
      f.input :district, label: 'Район'
      f.input :city, label: 'Город'
      f.input :condition, as: :select, collection: Property.conditions.keys, label: 'Состояние'
      f.input :user, label: 'Владелец'
    end
    f.actions
  end

  member_action :publish, method: :put do
    resource.publish!
    redirect_to admin_property_path(resource), notice: 'Объявление опубликовано'
  rescue AASM::InvalidTransition => e
    redirect_to admin_property_path(resource), alert: "Ошибка: #{e.message}"
  end

  member_action :unpublish, method: :put do
    resource.unpublish!
    redirect_to admin_property_path(resource), notice: 'Объявление снято с публикации'
  rescue AASM::InvalidTransition => e
    redirect_to admin_property_path(resource), alert: "Ошибка: #{e.message}"
  end

  action_item :publish, only: :show, if: -> { resource.pending? || resource.draft? } do
    link_to 'Опубликовать', publish_admin_property_path(resource), method: :put
  end

  action_item :unpublish, only: :show, if: -> { resource.active? } do
    link_to 'Снять с публикации', unpublish_admin_property_path(resource), method: :put
  end
end
