# frozen_string_literal: true

ActiveAdmin.register_page 'Dashboard' do
  menu priority: 1, label: proc { I18n.t('active_admin.dashboard') }

  content title: proc { I18n.t('active_admin.dashboard') } do
    columns do
      column do
        panel 'Пользователи' do
          ul do
            li "Всего: #{User.count}"
            li "Клиенты: #{User.clients.count}"
            li "Агенты: #{User.agents.count}"
            li "Администраторы: #{User.admins.count}"
            li "Не подтверждены: #{User.unconfirmed.count}"
          end
          div do
            link_to 'Управление пользователями', admin_users_path
          end
        end
      end

      column do
        panel 'Объявления' do
          ul do
            li "Всего: #{Property.unscoped.count}"
            li "На проверке: #{Property.unscoped.where(status: :pending).count}"
            li "Активные: #{Property.unscoped.where(status: :active).count}"
            li "Черновики: #{Property.unscoped.where(status: :draft).count}"
            li "Продано/Сдано: #{Property.unscoped.where(status: %i[sold rented]).count}"
          end
          div do
            link_to 'Управление объявлениями', admin_properties_path
          end
        end
      end

      column do
        panel 'Заявки' do
          ul do
            li "Всего: #{Inquiry.count}"
            li "Новые: #{Inquiry.where(status: :new).count}" rescue li 'Новые: —'
          end
          div do
            link_to 'Управление заявками', admin_inquiries_path
          end
        end
      end
    end

    columns do
      column do
        panel 'Последние регистрации' do
          table_for User.order(created_at: :desc).limit(5) do
            column('ID') { |u| link_to u.id, admin_user_path(u) }
            column('Email') { |u| u.email }
            column('Дата') { |u| u.created_at.strftime('%d.%m.%Y %H:%M') }
          end
        end
      end

      column do
        panel 'Последние объявления' do
          table_for Property.unscoped.order(created_at: :desc).limit(5) do
            column('ID') { |p| link_to p.id, admin_property_path(p) }
            column('Заголовок') { |p| truncate(p.title, length: 30) }
            column('Статус') { |p| p.status }
            column('Дата') { |p| p.created_at.strftime('%d.%m.%Y') }
          end
        end
      end
    end
  end
end
