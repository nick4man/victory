# frozen_string_literal: true

class DashboardController < ApplicationController
  before_action :authenticate_user!, if: -> { respond_to?(:authenticate_user!) }
  before_action :set_breadcrumbs
  
  layout 'dashboard'
  
  # ============================================
  # DASHBOARD HOME
  # ============================================
  
  # GET /dashboard
  def index
    # Load user statistics
    @statistics = load_user_statistics
    
    # Recent activity
    @recent_favorites = current_user.favorites
                                    .includes(property: [:property_type])
                                    .order(created_at: :desc)
                                    .limit(5)
    
    @recent_inquiries = current_user.inquiries
                                    .includes(:property)
                                    .order(created_at: :desc)
                                    .limit(5)
    
    @recent_views = current_user.recently_viewed_properties(10)
    
    @active_saved_searches = current_user.active_saved_searches
                                         .order(created_at: :desc)
                                         .limit(5)
    
    # Unread notifications count
    @unread_notifications_count = current_user.unread_notifications_count
    @unread_messages_count = current_user.unread_messages_count
    
    # Recommendations
    @recommended_properties = Property.recommended_for_user(current_user, 6)
    
    # Track dashboard visit
    track_event('dashboard_visited')
    
    respond_to do |format|
      format.html
      format.json { render json: dashboard_data }
    end
  end
  
  # ============================================
  # PROFILE
  # ============================================
  
  # GET /dashboard/profile
  def show_profile
    @user = current_user
    add_breadcrumb 'Профиль'
  end
  
  # GET /dashboard/profile/edit
  def edit_profile
    @user = current_user
    add_breadcrumb 'Профиль', dashboard_profile_path
    add_breadcrumb 'Редактирование'
  end
  
  # PATCH /dashboard/profile
  def update_profile
    @user = current_user
    
    if @user.update(profile_params)
      track_event('profile_updated')
      redirect_to dashboard_profile_path, notice: 'Профиль успешно обновлен'
    else
      add_breadcrumb 'Профиль', dashboard_profile_path
      add_breadcrumb 'Редактирование'
      render :edit_profile, status: :unprocessable_entity
    end
  end
  
  # ============================================
  # FAVORITES
  # ============================================
  
  # GET /dashboard/favorites
  def favorites
    @favorites = current_user.favorites
                            .includes(property: [:property_type, :user])
                            .order(created_at: :desc)
                            .page(params[:page])
                            .per(per_page)
    
    @total_count = current_user.favorites.count
    
    add_breadcrumb 'Избранное'
    
    track_event('favorites_viewed')
    
    respond_to do |format|
      format.html
      format.json { render json: favorites_json }
      format.pdf { render_favorites_pdf }
    end
  end
  
  # DELETE /dashboard/favorites/:id
  def destroy_favorite
    favorite = current_user.favorites.find(params[:id])
    favorite.destroy
    
    track_event('favorite_removed', { property_id: favorite.property_id })
    
    respond_to do |format|
      format.html { redirect_to dashboard_favorites_path, notice: 'Удалено из избранного' }
      format.json { render json: { success: true } }
    end
  end
  
  # DELETE /dashboard/favorites/clear_all
  def clear_all_favorites
    count = current_user.favorites.count
    current_user.favorites.destroy_all
    
    track_event('favorites_cleared', { count: count })
    
    redirect_to dashboard_favorites_path, notice: "Удалено объектов: #{count}"
  end
  
  # GET /dashboard/favorites/export
  def export_favorites
    @favorites = current_user.favorite_properties.published
    
    respond_to do |format|
      format.pdf do
        pdf = FavoritesPdfGenerator.new(@favorites, current_user)
        send_data pdf.render,
                  filename: "избранное_#{Date.current}.pdf",
                  type: 'application/pdf',
                  disposition: 'attachment'
      end
      format.xlsx do
        send_data FavoritesExcelGenerator.new(@favorites).render,
                  filename: "избранное_#{Date.current}.xlsx",
                  type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      end
    end
  end
  
  # ============================================
  # INQUIRIES
  # ============================================
  
  # GET /dashboard/inquiries
  def inquiries
    @inquiries = current_user.inquiries
                            .includes(:property, :agent)
                            .order(created_at: :desc)
                            .page(params[:page])
                            .per(per_page)
    
    # Filter by status if provided
    @inquiries = @inquiries.by_status(params[:status]) if params[:status].present?
    
    # Filter by type if provided
    @inquiries = @inquiries.by_type(params[:type]) if params[:type].present?
    
    @total_count = current_user.inquiries.count
    @active_count = current_user.inquiries.active.count
    @completed_count = current_user.inquiries.completed.count
    
    add_breadcrumb 'Мои заявки'
    
    track_event('inquiries_viewed')
    
    respond_to do |format|
      format.html
      format.json { render json: inquiries_json }
    end
  end
  
  # GET /dashboard/inquiries/:id
  def show_inquiry
    @inquiry = current_user.inquiries.find(params[:id])
    @timeline = @inquiry.timeline_events
    
    add_breadcrumb 'Мои заявки', dashboard_inquiries_path
    add_breadcrumb "Заявка ##{@inquiry.id}"
    
    respond_to do |format|
      format.html
      format.json { render json: inquiry_detail_json(@inquiry) }
    end
  end
  
  # DELETE /dashboard/inquiries/:id
  def destroy_inquiry
    @inquiry = current_user.inquiries.find(params[:id])
    
    if @inquiry.may_cancel?
      @inquiry.cancel!
      track_event('inquiry_cancelled', { inquiry_id: @inquiry.id })
      redirect_to dashboard_inquiries_path, notice: 'Заявка отменена'
    else
      redirect_to dashboard_inquiries_path, alert: 'Невозможно отменить заявку'
    end
  end
  
  # GET /dashboard/inquiries/:id/timeline
  def inquiry_timeline
    @inquiry = current_user.inquiries.find(params[:id])
    
    render json: { timeline: @inquiry.timeline_events }
  end
  
  # ============================================
  # SAVED SEARCHES
  # ============================================
  
  # GET /dashboard/saved_searches
  def saved_searches
    @saved_searches = current_user.saved_searches
                                  .order(created_at: :desc)
                                  .page(params[:page])
                                  .per(per_page)
    
    add_breadcrumb 'Сохраненные поиски'
    
    track_event('saved_searches_viewed')
  end
  
  # POST /dashboard/saved_searches/:id/activate
  def activate_saved_search
    @saved_search = current_user.saved_searches.find(params[:id])
    @saved_search.update(active: true)
    
    redirect_to dashboard_saved_searches_path, notice: 'Поиск активирован'
  end
  
  # POST /dashboard/saved_searches/:id/deactivate
  def deactivate_saved_search
    @saved_search = current_user.saved_searches.find(params[:id])
    @saved_search.update(active: false)
    
    redirect_to dashboard_saved_searches_path, notice: 'Поиск деактивирован'
  end
  
  # POST /dashboard/saved_searches/:id/check_new
  def check_new_saved_search
    @saved_search = current_user.saved_searches.find(params[:id])
    # Check for new properties matching this search
    # SavedSearchCheckJob.perform_later(@saved_search.id)
    
    redirect_to dashboard_saved_searches_path, notice: 'Проверка новых объектов запущена'
  end
  
  # ============================================
  # MESSAGES
  # ============================================
  
  # GET /dashboard/messages
  def messages
    @messages = current_user.received_messages
                           .includes(:sender, :property)
                           .order(created_at: :desc)
                           .page(params[:page])
                           .per(per_page)
    
    @unread_count = current_user.received_messages.where(read: false).count
    
    add_breadcrumb 'Сообщения'
    
    track_event('messages_viewed')
  end
  
  # GET /dashboard/messages/unread
  def unread_messages
    @messages = current_user.received_messages
                           .where(read: false)
                           .includes(:sender, :property)
                           .order(created_at: :desc)
    
    render json: { messages: @messages.map { |m| message_summary(m) } }
  end
  
  # POST /dashboard/messages/mark_all_read
  def mark_all_messages_read
    current_user.received_messages.where(read: false).update_all(read: true, read_at: Time.current)
    
    redirect_to dashboard_messages_path, notice: 'Все сообщения отмечены как прочитанные'
  end
  
  # GET /dashboard/messages/:id
  def show_message
    @message = current_user.received_messages.find(params[:id])
    @message.update(read: true, read_at: Time.current) unless @message.read?
    
    add_breadcrumb 'Сообщения', dashboard_messages_path
    add_breadcrumb @message.subject || "Сообщение ##{@message.id}"
  end
  
  # POST /dashboard/messages/:id/mark_read
  def mark_message_read
    @message = current_user.received_messages.find(params[:id])
    @message.update(read: true, read_at: Time.current)
    
    render json: { success: true, read: true }
  end
  
  # ============================================
  # NOTIFICATIONS
  # ============================================
  
  # GET /dashboard/notifications
  def notifications
    @notifications = current_user.notifications
                                 .order(created_at: :desc)
                                 .page(params[:page])
                                 .per(per_page)
    
    @unread_count = current_user.unread_notifications_count
    
    add_breadcrumb 'Уведомления'
  end
  
  # POST /dashboard/notifications/mark_all_read
  def mark_all_notifications_read
    current_user.mark_all_notifications_as_read!
    
    redirect_to dashboard_notifications_path, notice: 'Все уведомления прочитаны'
  end
  
  # POST /dashboard/notifications/:id/mark_read
  def mark_notification_read
    notification = current_user.notifications.find(params[:id])
    notification.update(read_at: Time.current)
    
    render json: { success: true }
  end
  
  # DELETE /dashboard/notifications/clear_all
  def clear_all_notifications
    current_user.notifications.destroy_all
    
    redirect_to dashboard_notifications_path, notice: 'Все уведомления удалены'
  end
  
  # ============================================
  # SETTINGS
  # ============================================
  
  # GET /dashboard/settings
  def settings
    @user = current_user
    add_breadcrumb 'Настройки'
  end
  
  # PATCH /dashboard/settings
  def update_settings
    if current_user.update(settings_params)
      track_event('settings_updated')
      redirect_to dashboard_settings_path, notice: 'Настройки сохранены'
    else
      @user = current_user
      add_breadcrumb 'Настройки'
      render :settings, status: :unprocessable_entity
    end
  end
  
  # GET /dashboard/settings/notifications
  def notification_settings
    @user = current_user
    add_breadcrumb 'Настройки', dashboard_settings_path
    add_breadcrumb 'Уведомления'
  end
  
  # PATCH /dashboard/settings/notifications
  def update_notification_settings
    if current_user.update(notification_settings_params)
      track_event('notification_settings_updated')
      redirect_to dashboard_settings_path, notice: 'Настройки уведомлений сохранены'
    else
      @user = current_user
      render :notification_settings, status: :unprocessable_entity
    end
  end
  
  # ============================================
  # VIEWING HISTORY
  # ============================================
  
  # GET /dashboard/history
  def history
    @viewed_properties = current_user.recently_viewed_properties(50)
                                     .page(params[:page])
                                     .per(per_page)
    
    add_breadcrumb 'История просмотров'
    
    track_event('history_viewed')
  end
  
  # DELETE /dashboard/history/clear
  def clear_history
    current_user.property_views.destroy_all
    
    track_event('history_cleared')
    redirect_to dashboard_history_path, notice: 'История просмотров очищена'
  end
  
  # ============================================
  # COMPARISONS
  # ============================================
  
  # GET /dashboard/comparisons
  def comparisons
    property_ids = session[:comparison_ids] || []
    @properties = Property.published.where(id: property_ids).limit(4)
    
    add_breadcrumb 'Сравнение объектов'
  end
  
  # DELETE /dashboard/comparisons/clear_all
  def clear_all_comparisons
    session[:comparison_ids] = []
    
    redirect_to properties_path, notice: 'Список сравнения очищен'
  end
  
  private
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  def set_breadcrumbs
    add_breadcrumb 'Личный кабинет', dashboard_root_path
  end
  
  # ============================================
  # STRONG PARAMETERS
  # ============================================
  
  def profile_params
    params.require(:user).permit(
      :first_name, :last_name, :phone, :email,
      :bio, :company, :position, :avatar
    )
  end
  
  def settings_params
    params.require(:user).permit(
      preferences: [:email_notifications, :sms_notifications, :push_notifications, :newsletter]
    )
  end
  
  def notification_settings_params
    params.require(:user).permit(
      notification_settings: [
        :new_properties, :price_changes, :new_messages,
        :inquiry_updates, :saved_search_results
      ]
    )
  end
  
  # ============================================
  # HELPERS
  # ============================================
  
  def load_user_statistics
    {
      favorites_count: current_user.favorites_count,
      inquiries_count: current_user.inquiries_count,
      active_inquiries: current_user.inquiries.active.count,
      properties_count: current_user.properties_count,
      active_properties: current_user.properties.active.count,
      total_views: current_user.properties.sum(:views_count),
      unread_messages: current_user.unread_messages_count,
      unread_notifications: current_user.unread_notifications_count,
      saved_searches: current_user.saved_searches.active.count,
      viewed_properties: current_user.property_views.count
    }
  end
  
  # ============================================
  # JSON RESPONSES
  # ============================================
  
  def dashboard_data
    {
      user: user_summary,
      statistics: @statistics,
      recent_favorites: @recent_favorites.map { |f| favorite_summary(f) },
      recent_inquiries: @recent_inquiries.map { |i| inquiry_summary(i) },
      recent_views: @recent_views.map { |p| property_summary(p) },
      recommended_properties: @recommended_properties.map { |p| property_summary(p) }
    }
  end
  
  def favorites_json
    {
      favorites: @favorites.map { |f| favorite_summary(f) },
      meta: pagination_meta(@favorites)
    }
  end
  
  def inquiries_json
    {
      inquiries: @inquiries.map { |i| inquiry_summary(i) },
      meta: pagination_meta(@inquiries),
      statistics: {
        total: @total_count,
        active: @active_count,
        completed: @completed_count
      }
    }
  end
  
  def user_summary
    {
      id: current_user.id,
      name: current_user.full_name,
      email: current_user.email,
      phone: current_user.formatted_phone,
      avatar_url: current_user.avatar_path
    }
  end
  
  def favorite_summary(favorite)
    {
      id: favorite.id,
      property: property_summary(favorite.property),
      created_at: favorite.created_at,
      note: favorite.note
    }
  end
  
  def inquiry_summary(inquiry)
    {
      id: inquiry.id,
      type: inquiry.inquiry_type,
      status: inquiry.status,
      property: inquiry.property ? property_summary(inquiry.property) : nil,
      created_at: inquiry.created_at,
      agent: inquiry.agent ? { name: inquiry.agent.full_name } : nil
    }
  end
  
  def inquiry_detail_json(inquiry)
    {
      id: inquiry.id,
      type: inquiry.inquiry_type,
      status: inquiry.status,
      name: inquiry.name,
      phone: inquiry.formatted_phone,
      email: inquiry.email,
      message: inquiry.message,
      property: inquiry.property ? property_detail(inquiry.property) : nil,
      agent: inquiry.agent ? agent_detail(inquiry.agent) : nil,
      timeline: inquiry.timeline_events,
      created_at: inquiry.created_at,
      updated_at: inquiry.updated_at
    }
  end
  
  def property_summary(property)
    {
      id: property.id,
      title: property.title,
      price: property.price,
      price_formatted: property.price_formatted,
      area: property.area,
      rooms: property.rooms,
      address: property.address,
      url: property_path(property),
      image_url: property.primary_image&.url
    }
  end
  
  def property_detail(property)
    property_summary(property).merge(
      description: property.short_description,
      floor: property.floor,
      total_floors: property.total_floors
    )
  end
  
  def agent_detail(agent)
    {
      id: agent.id,
      name: agent.full_name,
      phone: agent.formatted_phone,
      email: agent.email,
      avatar_url: agent.avatar_path
    }
  end
  
  def message_summary(message)
    {
      id: message.id,
      subject: message.subject,
      body: message.body.truncate(100),
      sender: message.sender.full_name,
      read: message.read,
      created_at: message.created_at
    }
  end
  
  def pagination_meta(collection)
    {
      current_page: collection.current_page,
      total_pages: collection.total_pages,
      total_count: collection.total_count,
      per_page: collection.limit_value
    }
  end
  
  def render_favorites_pdf
    # PDF generation logic
    # pdf = WickedPdf.new.pdf_from_string(
    #   render_to_string('dashboard/favorites_pdf', layout: 'pdf')
    # )
    # send_data pdf, filename: "favorites_#{Date.current}.pdf", type: 'application/pdf'
  end
end