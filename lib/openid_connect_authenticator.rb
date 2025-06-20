# frozen_string_literal: true

class OpenIDConnectAuthenticator < Auth::ManagedAuthenticator
  def name
    "oidc"
  end

  def can_revoke?
    SiteSetting.openid_connect_allow_association_change
  end

  def can_connect_existing_user?
    SiteSetting.openid_connect_allow_association_change
  end

  def enabled?
    SiteSetting.openid_connect_enabled
  end

  def provides_groups?
    SiteSetting.openid_connect_roles_claim_name
  end

  def set_admin!(user, associated_groups)
    if associated_groups.any? {|group| group["name"] == "admin" } or associated_groups.any? {|group| group[:name] == "admin" }
      if user.admin != true
        oidc_log("Assoiated groups contain admin, granting admin to user")
        user.grant_admin!
      end
    else
      if user.admin == true
        oidc_log("Assoiated groups don't contain admin so removing as an admin")
        user.revoke_admin!
      end
    end
  end

  def after_create_account(user, auth)
    associated_groups = auth.associated_groups
    set_admin!(user, associated_groups)
  end

  def after_authenticate(auth_token, existing_account: nil)
    result = super

    associated_groups=[]
    decoded = ::JWT.decode(auth_token.extra[:id_token], nil, false).first
    if decoded[SiteSetting.openid_connect_roles_claim_name]
      roles = decoded[SiteSetting.openid_connect_roles_claim_name]
      associated_groups = roles.map.with_index { |role, id| {id: (100 + id).to_s, name: role} }
    end
    result.associated_groups = associated_groups

    if result.user
      user = result.user
      set_admin!(user, associated_groups)
    end

    result
  end

  def primary_email_verified?(auth)
    supplied_verified_boolean = auth["extra"]["raw_info"]["email_verified"]
    # If the payload includes the email_verified boolean, use it. Otherwise assume true
    if supplied_verified_boolean.nil?
      true
    else
      # Many providers violate the spec, and send this as a string rather than a boolean
      supplied_verified_boolean == true ||
        (supplied_verified_boolean.is_a?(String) && supplied_verified_boolean.downcase == "true")
    end
  end

  def always_update_user_email?
    SiteSetting.openid_connect_overrides_email
  end

  def match_by_email
    SiteSetting.openid_connect_match_by_email
  end

  def discovery_document
    document_url = SiteSetting.openid_connect_discovery_document.presence
    if !document_url
      oidc_log("No discovery document URL specified", error: true)
      return
    end

    from_cache = true
    result =
      Discourse
        .cache
        .fetch("openid-connect-discovery-#{document_url}", expires_in: 10.minutes) do
          from_cache = false
          oidc_log("Fetching discovery document from #{document_url}")
          connection =
            Faraday.new(request: { timeout: request_timeout_seconds }) do |c|
              c.use Faraday::Response::RaiseError
              c.adapter FinalDestination::FaradayAdapter
            end
          JSON.parse(connection.get(document_url).body)
        rescue Faraday::Error, JSON::ParserError => e
          oidc_log("Fetching discovery document raised error #{e.class} #{e.message}", error: true)
          nil
        end

    oidc_log("Discovery document loaded from cache") if from_cache
    oidc_log("Discovery document is\n\n#{result.to_yaml}")

    result
  end

  def oidc_log(message, error: false)
    if error
      Rails.logger.error("OIDC Log: #{message}")
    elsif SiteSetting.openid_connect_verbose_logging
      Rails.logger.warn("OIDC Log: #{message}")
    end
  end

  def register_middleware(omniauth)
    omniauth.provider :openid_connect,
                      name: :oidc,
                      error_handler:
                        lambda { |error, message|
                          handlers = SiteSetting.openid_connect_error_redirects.split("\n")
                          handlers.each do |row|
                            parts = row.split("|")
                            return parts[1] if message.include? parts[0]
                          end
                          nil
                        },
                      verbose_logger: lambda { |message| oidc_log(message) },
                      setup:
                        lambda { |env|
                          opts = env["omniauth.strategy"].options

                          token_params = {}
                          token_params[
                            :scope
                          ] = SiteSetting.openid_connect_token_scope if SiteSetting.openid_connect_token_scope.present?

                          opts.deep_merge!(
                            client_id: SiteSetting.openid_connect_client_id,
                            client_secret: SiteSetting.openid_connect_client_secret,
                            discovery_document: discovery_document,
                            scope: SiteSetting.openid_connect_authorize_scope,
                            token_params: token_params,
                            passthrough_authorize_options:
                              SiteSetting.openid_connect_authorize_parameters.split("|"),
                            claims: SiteSetting.openid_connect_claims,
                          )

                          opts[:client_options][:connection_opts] = {
                            request: {
                              timeout: request_timeout_seconds,
                            },
                          }

                          opts[:client_options][:connection_build] = lambda do |builder|
                            if SiteSetting.openid_connect_verbose_logging
                              builder.response :logger,
                                               Rails.logger,
                                               { bodies: true, formatter: OIDCFaradayFormatter }
                            end

                            builder.request :url_encoded # form-encode POST params
                            builder.adapter FinalDestination::FaradayAdapter # make requests with FinalDestination::HTTP
                          end
                        }
  end

  def request_timeout_seconds
    GlobalSetting.openid_connect_request_timeout_seconds
  end
end
