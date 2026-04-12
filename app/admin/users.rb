# frozen_string_literal: true

ActiveAdmin.register User do
  menu label: 'Пользователи', priority: 2

  permit_params :email, :password, :password_confirmation,
                :first_name, :last_name, :phone, :role, :active

  index do
    selectable_column
    id_column
    column :full_name
    column :email
    column('Роль') { |u| User.roles.key(u.role) }
    column :active
    column :confirmed_at
    column :sign_in_count
    column :created_at
    actions
  end

  filter :email
  filter :first_name
  filter :last_name
  filter :role, as: :select, collection: User.roles
  filter :active
  filter :created_at

  show do
    attributes_table do
      row :id
      row :full_name
      row :email
      row :phone
      row('Роль') { |u| User.roles.key(u.role) }
      row :active
      row :confirmed_at
      row :sign_in_count
      row :last_sign_in_at
      row :created_at
      row :updated_at
    end
  end

  form do |f|
    f.inputs 'Основные данные' do
      f.input :first_name, label: 'Имя'
      f.input :last_name, label: 'Фамилия'
      f.input :email
      f.input :phone, label: 'Телефон'
      f.input :role, as: :select, collection: User.roles.keys, label: 'Роль'
      f.input :active, label: 'Активен'
    end
    f.inputs 'Пароль' do
      f.input :password, label: 'Новый пароль'
      f.input :password_confirmation, label: 'Подтверждение пароля'
    end
    f.actions
  end

  action_item :confirm, only: :show, if: -> { !resource.confirmed? } do
    link_to 'Подтвердить', confirm_admin_user_path(resource), method: :put
  end

  member_action :confirm, method: :put do
    resource.confirm
    redirect_to admin_user_path(resource), notice: 'Пользователь подтверждён'
  end
end
