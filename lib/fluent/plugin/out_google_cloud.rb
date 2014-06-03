module Fluent
  class GoogleCloudOutput < BufferedOutput
    Fluent::Plugin.register_output('google_cloud', self)

    # Legal values:
    # 'compute_engine_service_account' - Use the service account automatically
    #   available on Google Compute Engine VMs. Note that this requires that
    #   the logs.writeonly API scope is enabled on the VM, and scopes can
    #   only be enabled at the time that a VM is created.
    # 'private_key' - Use the service account credentials (email, private key
    #   local file path, and file passphrase) provided below.
    config_param :auth_method, :string,
      :default => 'compute_engine_service_account'

    # Parameters necessary to use the private_key auth_method.
    config_param :private_key_email, :string, :default => nil
    config_param :private_key_path, :string, :default => nil
    config_param :private_key_passphrase, :string, :default => 'notasecret'

    # TODO: Add a log_name config option rather than just using the tag?

    # Expose attr_readers to make testing of metadata more direct than only
    # testing it indirectly through metadata sent with logs.
    attr_reader :project_id
    attr_reader :zone
    attr_reader :vm_id
    attr_reader :running_on_managed_vm
    attr_reader :gae_backend_name
    attr_reader :gae_backend_version

    def initialize
      super
      require 'google/api_client'
      require 'google/api_client/auth/compute_service_account'
      require 'open-uri'
    end

    def configure(conf)
      super

      case @auth_method
      when 'private_key'
        if !@private_key_email
          raise Fluent::ConfigError, '"private_key_email" must be specified '\
                                     'if auth_method is "private_key"'
        elsif !@private_key_path
          raise Fluent::ConfigError, '"private_key_path" must be specified '\
                                     'if auth_method is "private_key"'
        elsif !@private_key_passphrase
          raise Fluent::ConfigError, '"private_key_passphrase" must be '\
                                     'specified if auth_method is "private_key"'
        end
      when 'compute_engine_service_account'
        # pass
      else
        raise Fluent::ConfigError,
          'Unrecognized "auth_method" parameter. Please specify either '\
          '"compute_engine_service_account" or "private_key".'
      end
    end

    def start
      super

      init_api_client()
      # TODO: Switch over to using this when the logs API is discoverable.
      #@api = api_client().discovered_api('logs', 'v1')

      # Grab metadata about the Google Compute Engine instance that we're on.
      @project_id = fetch_metadata('project/numeric-project-id')
      fully_qualified_zone = fetch_metadata('instance/zone')
      @zone = fully_qualified_zone.rpartition('/')[2]
      @vm_id = fetch_metadata('instance/id')
      # TODO: Send instance tags and/or hostname with the logs as well?

      # If this is running on a Managed VM, grab the relevant App Engine
      # metadata as well.
      # TODO: Use a configuration flag instead of detecting automatically?
      attributes_string = fetch_metadata('instance/attributes/')
      attributes = attributes_string.split
      if attributes.include?('gae_backend_name') &&
         attributes.include?('gae_backend_version')
        @running_on_managed_vm = true
        @gae_backend_name =
          fetch_metadata('instance/attributes/gae_backend_name')
        @gae_backend_version =
          fetch_metadata('instance/attributes/gae_backend_version')
      else
        @running_on_managed_vm = false
      end
    end

    def shutdown
      super
    end

    def format(tag, time, record)
      [tag, time, record['message']].to_msgpack
    end

    def write(chunk)
      payload = {
        'metadata' => {
          'location' => @zone
        },
        'logEntry' => {}
      }
      if @running_on_managed_vm
        payload['metadata']['appEngine'] = {
          'moduleId' => @gae_backend_name,
          'versionId' => @gae_backend_version,
          'computeEngineVmId' => @vm_id
        }
      else
        payload['metadata']['computeEngine'] = { 'instanceId' => @vm_id }
      end

      # TODO: Add in calls for creating log streams?
      chunk.msgpack_each do |row_object|
        # Ignore the extra info that can be automatically appended to the tag
        # for certain log types such as syslog.
        url = "https://www.googleapis.com/logs/v1beta/projects/#{@project_id}/logs/#{row_object[0]}/entries"
        payload['metadata']['timeNanos'] = row_object[1] * 1000000000
        payload['logEntry']['details'] = row_object[2]
        
        options = {:uri => url, :body_object => payload.to_json,
                   :http_method => 'POST', :authenticated => true}
        client = api_client()
        # TODO: Either handle errors locally or send all logs in a single
        # request. Otherwise if a single request raises an error, the buffering
        # plugin will retry the entire block, potentially leading to duplicates.
        request = client.generate_request({
          :uri => url,
          :body_object => payload,
          :http_method => 'POST',
          :authenticated => true
        })
        client.execute!(request)
      end
    end

    private

    def fetch_metadata(metadata_path)
      open('http://metadata/computeMetadata/v1/' + metadata_path,
           {'Metadata-Flavor' => 'Google'}) { |f|
        f.read
      }
    end

    def init_api_client
      @client = Google::APIClient.new(
        :application_name => 'Fluentd Google Cloud Logging plugin',
        # TODO: Set this from a shared configuration file.
        :application_version => '0.1.0')

      if @auth_method == 'private_key'
        key = Google::APIClient::PKCS12.load_key(@private_key_path,
                                                 @private_key_passphrase)
        jwt_asserter = Google::APIClient::JWTAsserter.new(
          @private_key_email, "https://www.googleapis.com/auth/logs.writeonly",
          key)
        @client.authorization = jwt_asserter.to_authorization
        @client.authorization.expiry = 3600  # 3600s is the max allowed value
      else
        @client.authorization = Google::APIClient::ComputeServiceAccount.new
      end
    end

    def api_client
      if !@client.authorization.expired?
        @client.authorization.fetch_access_token!
      end
      return @client
    end
  end
end
