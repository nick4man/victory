# frozen_string_literal: true

# Application Helper
# General helper methods available across all views
module ApplicationHelper
  # Format currency with proper Russian formatting
  def format_price(price, options = {})
    return '—' if price.blank? || price.zero?
    
    number_to_currency(
      price,
      options.reverse_merge(
        unit: '₽',
        separator: ',',
        delimiter: ' ',
        format: '%n %u',
        precision: options[:precision] || 0
      )
    )
  end
  
  # Format area with m² symbol
  def format_area(area)
    return '—' if area.blank?
    
    "#{number_with_delimiter(area, delimiter: ' ')} м²"
  end
  
  # Format phone number to Russian format
  def format_phone(phone)
    return '' unless phone.present?
    
    # Remove all non-digit characters except +
    clean = phone.gsub(/[^\d+]/, '')
    
    # Format as +7 (999) 123-45-67
    if clean.match?(/^(\+?7|8)(\d{3})(\d{3})(\d{2})(\d{2})$/)
      clean.sub(/^(\+?7|8)(\d{3})(\d{3})(\d{2})(\d{2})$/, '+7 (\2) \3-\4-\5')
    else
      phone
    end
  end
  
  # Generate page title
  def page_title(title = nil)
    base_title = 'АН "Виктори"'
    
    if title.present?
      "#{title} | #{base_title}"
    else
      "#{base_title} - Агентство недвижимости"
    end
  end
  
  # Generate meta description
  def meta_description(description = nil)
    description.presence || 'АН "Виктори" - профессиональное агентство недвижимости. Покупка, продажа, аренда квартир и домов. Помощь с ипотекой.'
  end
  
  # Format date in Russian style
  def format_date(date, format: :default)
    return '—' unless date.present?
    
    I18n.l(date, format: format)
  end
  
  # Format datetime in Russian style
  def format_datetime(datetime, format: :default)
    return '—' unless datetime.present?
    
    I18n.l(datetime, format: format)
  end
  
  # Flash message CSS classes
  def flash_class(type)
    case type.to_sym
    when :notice, :success
      'bg-green-100 border-green-400 text-green-700'
    when :alert, :error
      'bg-red-100 border-red-400 text-red-700'
    when :warning
      'bg-yellow-100 border-yellow-400 text-yellow-700'
    else
      'bg-blue-100 border-blue-400 text-blue-700'
    end
  end
  
  # Flash message icons
  def flash_icon(type)
    case type.to_sym
    when :notice, :success
      '✅'
    when :alert, :error
      '❌'
    when :warning
      '⚠️'
    else
      'ℹ️'
    end
  end
  
  # Property type translation with icon
  def property_type_with_icon(type)
    icons = {
      'apartment' => '🏢',
      'house' => '🏠',
      'townhouse' => '🏘️',
      'land' => '🌳',
      'commercial' => '🏪',
      'garage' => '🚗'
    }
    
    icon = icons[type] || '🏠'
    text = I18n.t("property_types.#{type}")
    
    "#{icon} #{text}"
  end
  
  # Deal type badge
  def deal_type_badge(type)
    color = case type
            when 'sale'
              'bg-green-100 text-green-800'
            when 'rent'
              'bg-blue-100 text-blue-800'
            else
              'bg-gray-100 text-gray-800'
            end
    
    content_tag(:span, I18n.t("deal_types.#{type}"), class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color}")
  end
  
  # Property status badge
  def property_status_badge(status)
    config = {
      'active' => { color: 'bg-green-100 text-green-800', icon: '✅' },
      'pending' => { color: 'bg-yellow-100 text-yellow-800', icon: '⏳' },
      'sold' => { color: 'bg-gray-100 text-gray-800', icon: '✔️' },
      'rented' => { color: 'bg-blue-100 text-blue-800', icon: '✔️' },
      'archived' => { color: 'bg-red-100 text-red-800', icon: '📦' }
    }
    
    conf = config[status] || config['pending']
    text = "#{conf[:icon]} #{I18n.t("property_statuses.#{status}")}"
    
    content_tag(:span, text, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{conf[:color]}")
  end
  
  # Inquiry status badge
  def inquiry_status_badge(status)
    config = {
      'pending' => { color: 'bg-yellow-100 text-yellow-800', icon: '⏳' },
      'in_progress' => { color: 'bg-blue-100 text-blue-800', icon: '🔄' },
      'completed' => { color: 'bg-green-100 text-green-800', icon: '✅' },
      'cancelled' => { color: 'bg-red-100 text-red-800', icon: '❌' }
    }
    
    conf = config[status] || config['pending']
    text = "#{conf[:icon]} #{I18n.t("inquiry_statuses.#{status}")}"
    
    content_tag(:span, text, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{conf[:color]}")
  end
  
  # Generate breadcrumbs
  def breadcrumbs(items)
    content_tag(:nav, class: 'flex', aria: { label: 'Breadcrumb' }) do
      content_tag(:ol, class: 'inline-flex items-center space-x-1 md:space-x-3') do
        items.map.with_index do |(text, url), index|
          content_tag(:li, class: 'inline-flex items-center') do
            if index.zero?
              link_to url, class: 'inline-flex items-center text-sm font-medium text-gray-700 hover:text-blue-600' do
                safe_join([
                  content_tag(:svg, class: 'w-3 h-3 mr-2.5', fill: 'currentColor', viewBox: '0 0 20 20', xmlns: 'http://www.w3.org/2000/svg') do
                    content_tag(:path, '', d: 'M10.707 2.293a1 1 0 00-1.414 0l-7 7a1 1 0 001.414 1.414L4 10.414V17a1 1 0 001 1h2a1 1 0 001-1v-2a1 1 0 011-1h2a1 1 0 011 1v2a1 1 0 001 1h2a1 1 0 001-1v-6.586l.293.293a1 1 0 001.414-1.414l-7-7z')
                  end,
                  text
                ])
              end
            elsif url.present?
              safe_join([
                content_tag(:svg, class: 'w-3 h-3 text-gray-400 mx-1', fill: 'currentColor', viewBox: '0 0 20 20', xmlns: 'http://www.w3.org/2000/svg') do
                  content_tag(:path, '', 'fill-rule': 'evenodd', d: 'M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z', 'clip-rule': 'evenodd')
                end,
                link_to(text, url, class: 'ml-1 text-sm font-medium text-gray-700 hover:text-blue-600 md:ml-2')
              ])
            else
              safe_join([
                content_tag(:svg, class: 'w-3 h-3 text-gray-400 mx-1', fill: 'currentColor', viewBox: '0 0 20 20', xmlns: 'http://www.w3.org/2000/svg') do
                  content_tag(:path, '', 'fill-rule': 'evenodd', d: 'M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z', 'clip-rule': 'evenodd')
                end,
                content_tag(:span, text, class: 'ml-1 text-sm font-medium text-gray-500 md:ml-2')
              ])
            end
          end
        end.inject(:+)
      end
    end
  end
  
  # Truncate text with custom ending
  def smart_truncate(text, length: 100, separator: ' ', omission: '...')
    return '' if text.blank?
    
    text = strip_tags(text)
    
    return text if text.length <= length
    
    truncate(text, length: length, separator: separator, omission: omission)
  end
  
  # Avatar or initials
  def user_avatar(user, size: 'medium')
    sizes = {
      'small' => 'w-8 h-8 text-xs',
      'medium' => 'w-10 h-10 text-sm',
      'large' => 'w-16 h-16 text-xl',
      'xlarge' => 'w-24 h-24 text-3xl'
    }
    
    size_class = sizes[size] || sizes['medium']
    
    if user.avatar.present?
      image_tag(user.avatar.url, class: "#{size_class} rounded-full", alt: user.full_name)
    else
      initials = user.full_name.split.map(&:first).join.upcase[0..1]
      content_tag(:div, initials, class: "#{size_class} rounded-full bg-gradient-to-br from-purple-500 to-pink-500 flex items-center justify-center text-white font-bold")
    end
  end
  
  # Social share buttons
  def social_share_buttons(url, title)
    content_tag(:div, class: 'flex space-x-2') do
      safe_join([
        link_to("https://vk.com/share.php?url=#{CGI.escape(url)}&title=#{CGI.escape(title)}",
                target: '_blank',
                class: 'inline-flex items-center justify-center w-10 h-10 rounded-full bg-blue-600 text-white hover:bg-blue-700 transition-colors',
                title: 'Поделиться ВКонтакте') do
          content_tag(:span, 'VK', class: 'text-xs font-bold')
        end,
        
        link_to("https://t.me/share/url?url=#{CGI.escape(url)}&text=#{CGI.escape(title)}",
                target: '_blank',
                class: 'inline-flex items-center justify-center w-10 h-10 rounded-full bg-sky-500 text-white hover:bg-sky-600 transition-colors',
                title: 'Поделиться в Telegram') do
          content_tag(:span, 'TG', class: 'text-xs font-bold')
        end,
        
        link_to("https://wa.me/?text=#{CGI.escape(title + ' ' + url)}",
                target: '_blank',
                class: 'inline-flex items-center justify-center w-10 h-10 rounded-full bg-green-500 text-white hover:bg-green-600 transition-colors',
                title: 'Поделиться в WhatsApp') do
          content_tag(:span, 'WA', class: 'text-xs font-bold')
        end
      ])
    end
  end
  
  # Loading spinner
  def loading_spinner(size: 'medium')
    sizes = {
      'small' => 'w-4 h-4',
      'medium' => 'w-8 h-8',
      'large' => 'w-12 h-12'
    }
    
    size_class = sizes[size] || sizes['medium']
    
    content_tag(:div, class: "#{size_class} border-4 border-gray-200 border-t-blue-600 rounded-full animate-spin") {}
  end
end

