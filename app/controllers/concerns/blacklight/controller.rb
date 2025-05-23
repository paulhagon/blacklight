# frozen_string_literal: true

# Filters added to this controller apply to all controllers in the hosting application
# as this module is mixed-in to the application controller in the hosting app on installation.
module Blacklight::Controller
  extend ActiveSupport::Concern

  included do
    include ActiveSupport::Callbacks

    # now in application.rb file under config.filter_parameters
    # filter_parameter_logging :password, :password_confirmation

    # handle basic authorization exception with #access_denied
    rescue_from Blacklight::Exceptions::AccessDenied, with: :access_denied
    helper BlacklightHelper

    if respond_to? :helper_method
      helper_method :current_user_session, :current_user, :current_or_guest_user

      # extra head content
      helper_method :has_user_authentication_provider?
      helper_method :blacklight_config, :blacklight_configuration_context # move to Catalog
      helper_method :search_action_url, :search_action_path
      helper_method :search_state
    end

    # Which class to use for the search state. You can subclass SearchState if you
    # want to override any of the methods (e.g. SearchState#url_for_document)
    # TODO: move to Searchable
    class_attribute :search_state_class
    self.search_state_class = Blacklight::SearchState
  end

  # @private
  def default_catalog_controller
    CatalogController
  end

  delegate :blacklight_config, to: :default_catalog_controller

  private

  ##
  # Context in which to evaluate blacklight configuration conditionals
  # TODO: move to catalog?
  def blacklight_configuration_context
    @blacklight_configuration_context ||= Blacklight::Configuration::Context.new(self)
  end

  ##
  # Determine whether to render the bookmarks control
  # (Needs to be available globally, as it is used in the navbar)
  def render_bookmarks_control?
    has_user_authentication_provider? && current_or_guest_user.present?
  end

  # This must be on every controller that uses the layout, because it is used in
  # the header to draw Blacklight::SearchNavbarComponent (via the shared/header_navbar template)
  # @return [Blacklight::SearchState] a memoized instance of the parameter state.
  def search_state
    @search_state ||= search_state_class.new(params, blacklight_config, self)
  end

  # Default route to the search action (used e.g. in global partials). Override this method
  # in a controller or in your ApplicationController to introduce custom logic for choosing
  # which action the search form should use
  def search_action_url options = {}
    # Rails 4.2 deprecated url helpers accepting string keys for 'controller' or 'action'
    search_catalog_url(options.to_h.except(:controller, :action))
  end

  def search_action_path *args
    if args.first.is_a? Hash
      args.first[:only_path] = true if args.first[:only_path].nil?
    end

    search_action_url(*args)
  end

  # Should be provided by authentication provider
  # def current_user
  # end
  # def current_or_guest_user
  # end

  # Here's a stub implementation we'll add if it isn't provided for us
  def current_or_guest_user
    if defined? super
      super
    elsif has_user_authentication_provider?
      current_user
    end
  end
  alias blacklight_current_or_guest_user current_or_guest_user

  ##
  #
  #
  def has_user_authentication_provider?
    respond_to? :current_user
  end

  ##
  # When a user logs in, transfer any saved searches or bookmarks to the current_user
  def transfer_guest_to_user
    return unless respond_to?(:current_user) && respond_to?(:guest_user) && current_user && guest_user

    current_user_searches = current_user.searches.pluck(:query_params)
    current_user_bookmarks = current_user.bookmarks.pluck(:document_id)

    guest_user.searches.reject { |s| current_user_searches.include?(s.query_params) }.each do |s|
      current_user.searches << s
      s.save!
    end

    guest_user.bookmarks.reject { |b| current_user_bookmarks.include?(b.document_id) }.each do |b|
      current_user.bookmarks << b
      b.save!
    end

    # let guest_user know we've moved some bookmarks from under it
    guest_user.reload if guest_user.persisted?
  end

  ##
  # To handle failed authorization attempts, redirect the user to the
  # login form and persist the current request uri as a parameter
  def access_denied
    # send the user home if the access was previously denied by the same
    # request to avoid sending the user back to the login page
    #   (e.g. protected page -> logout -> returned to protected page -> home)
    redirect_to(root_url) && flash.discard && return if request.referer&.ends_with?(request.fullpath)

    redirect_to(root_url) && return unless has_user_authentication_provider?

    redirect_to new_user_session_url(referer: request.fullpath)
  end

  def determine_layout
    'blacklight'
  end
end
