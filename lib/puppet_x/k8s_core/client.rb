# frozen_string_literal: true

require 'English'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'
require 'base64'
require 'time'

module PuppetX
  module K8sCore
    # Raised for usage and state errors. A Puppet::Error when Puppet is loaded,
    # so failures render cleanly in reports; plain StandardError under facter.
    Error = Class.new(defined?(Puppet::Error) ? Puppet::Error : StandardError) unless const_defined?(:Error)

    # An error response from the Kubernetes API server.
    class ApiError < StandardError
      attr_reader :code, :body, :status

      def initialize(code, body, verb, path)
        @code = code.to_i
        @body = body
        @status = begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError
          nil
        end
        detail = (@status.is_a?(Hash) && @status['message']) ? @status['message'] : body.to_s[0, 500]
        super("#{verb} #{path}: HTTP #{code}: #{detail}")
      end

      def not_found?
        code == 404
      end

      def conflict?
        code == 409
      end

      def forbidden?
        code == 403
      end

      # The field managers named in a server-side apply conflict (HTTP 409).
      def conflict_managers
        causes = (@status.is_a?(Hash) && @status.dig('details', 'causes')) || []
        causes.map { |c| c['message'].to_s[%r{conflict with "([^"]+)"}, 1] }.compact.uniq
      end
    end

    # A minimal Kubernetes REST client built on the Ruby standard library only,
    # so the module can be vendored into openvox-agent without gem dependencies.
    #
    # One instance holds one keep-alive connection and a discovery cache; it is
    # not thread-safe, which matches how Puppet applies a catalog.
    class Client
      RETRYABLE = [429, 500, 502, 503, 504].freeze
      SA_DIR = '/var/run/secrets/kubernetes.io/serviceaccount'

      attr_reader :server, :description

      # @param server [String] API server URL, e.g. https://10.96.0.1:443
      # @param token [String] bearer token
      # @param token_file [String] file re-read when it changes (projected SA tokens rotate)
      # @param exec [Hash] kubeconfig exec credential plugin spec
      def initialize(server:, token: nil, token_file: nil, ca_file: nil, ca_data: nil,
                     client_cert_data: nil, client_key_data: nil, insecure: false,
                     exec: nil, timeout: 30, description: nil)
        @server = server.to_s.sub(%r{/+\z}, '')
        @uri = URI.parse(@server)
        @token = token
        @token_file = token_file
        @ca_file = ca_file
        @ca_data = ca_data
        @client_cert_data = client_cert_data
        @client_key_data = client_key_data
        @insecure = insecure
        @exec = exec
        @timeout = timeout
        @description = description || @server
        @discovery = nil
        @discovery_fetched_at = nil
      end

      # ---- HTTP -----------------------------------------------------------

      def request(verb, path, body: nil, query: {}, content_type: 'application/json', accept: 'application/json', raw: false)
        full = path.dup
        q = query.compact.reject { |_k, v| v == '' }
        full << "?#{URI.encode_www_form(q)}" unless q.empty?
        attempts = 0
        begin
          attempts += 1
          req = build_request(verb, full, body, content_type, accept)
          res = connection.request(req)
          code = res.code.to_i
          if RETRYABLE.include?(code) && attempts < 4
            sleep(retry_delay(res, attempts))
            raise RetryRequest
          end
          raise ApiError.new(code, res.body, verb.to_s.upcase, path) unless code.between?(200, 299)

          return res.body.to_s if raw

          (res.body.nil? || res.body.empty?) ? {} : JSON.parse(res.body)
        rescue RetryRequest
          retry
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
          reset_connection
          raise e.class, "#{verb.to_s.upcase} #{@server}#{path}: #{e.message}" if attempts >= 3

          sleep(attempts * 0.5)
          retry
        end
      end

      class RetryRequest < StandardError; end

      def get(path, **opts)
        request(:get, path, **opts)
      end

      def close
        @http&.finish if @http&.started?
      rescue IOError
        nil
      ensure
        @http = nil
      end

      # ---- discovery ------------------------------------------------------

      # Every served resource, keyed by "apiVersion/Kind"; values carry the
      # plural name and scope. Uses aggregated discovery (two requests) and
      # falls back to per-group discovery on servers older than 1.30.
      def discovery(refresh: false)
        return @discovery if @discovery && !refresh

        @discovery = aggregated_discovery || legacy_discovery
        @discovery_fetched_at = Time.now
        @discovery
      end

      # @return [Hash, nil] { 'plural' =>, 'namespaced' =>, 'verbs' => }
      def resource_info(api_version, kind)
        key = "#{api_version}/#{kind}"
        info = discovery[key]
        return info if info

        # A CRD applied earlier in this run is not in the cache yet.
        info = discovery(refresh: true)[key] if @discovery_fetched_at.nil? || Time.now - @discovery_fetched_at > 1
        info
      end

      # Waits for a kind to be served, e.g. after its CRD was just created.
      def wait_for_kind(api_version, kind, timeout: 60)
        deadline = Time.now + timeout
        loop do
          info = resource_info(api_version, kind)
          return info if info
          raise Error, "#{api_version} #{kind} is not served by #{@description}" if Time.now > deadline

          sleep 2
        end
      end

      def resource_path(api_version, kind, namespace, name = nil, info: nil)
        info ||= resource_info(api_version, kind)
        raise Error, "#{api_version} #{kind} is not served by #{@description}" unless info

        base = api_version.include?('/') ? "/apis/#{api_version}" : "/api/#{api_version}"
        if info['namespaced']
          raise Error, "#{kind} is namespaced; name it as #{kind}/<namespace>/<name>" if namespace.to_s.empty?

          base += "/namespaces/#{esc(namespace)}"
        elsif !namespace.to_s.empty?
          raise Error, "#{kind} is cluster-scoped; name it as #{kind}/<name> without a namespace"
        end
        path = "#{base}/#{info['plural']}"
        name ? "#{path}/#{esc(name)}" : path
      end

      # ---- object operations ----------------------------------------------

      def get_object(api_version, kind, namespace, name)
        get(resource_path(api_version, kind, namespace, name))
      rescue ApiError => e
        raise unless e.not_found?

        nil
      end

      # Server-side apply. Creates the object if it does not exist.
      def apply(object, field_manager:, force: false, dry_run: false)
        md = object['metadata'] || {}
        path = resource_path(object['apiVersion'], object['kind'], md['namespace'], md['name'])
        request(:patch, path,
                body: object,
                content_type: 'application/apply-patch+yaml',
                query: { 'fieldManager' => field_manager, 'force' => force ? 'true' : nil,
                         'dryRun' => dry_run ? 'All' : nil, 'fieldValidation' => 'Strict', })
      end

      def delete_object(api_version, kind, namespace, name, propagation: 'Foreground')
        request(:delete, resource_path(api_version, kind, namespace, name),
                body: { 'kind' => 'DeleteOptions', 'apiVersion' => 'v1', 'propagationPolicy' => propagation })
      rescue ApiError => e
        raise unless e.not_found?

        nil
      end

      # Lists objects, following pagination.
      def list_objects(api_version, kind, namespace: nil, label_selector: nil, field_selector: nil)
        info = resource_info(api_version, kind)
        raise Error, "#{api_version} #{kind} is not served by #{@description}" unless info

        base = api_version.include?('/') ? "/apis/#{api_version}" : "/api/#{api_version}"
        base += "/namespaces/#{esc(namespace)}" if info['namespaced'] && namespace
        path = "#{base}/#{info['plural']}"
        items = []
        token = nil
        loop do
          page = get(path, query: { 'labelSelector' => label_selector, 'fieldSelector' => field_selector,
                                    'limit' => 500, 'continue' => token, })
          (page['items'] || []).each do |item|
            item['apiVersion'] ||= api_version
            item['kind'] ||= kind
            items << item
          end
          token = page.dig('metadata', 'continue')
          break if token.nil? || token.empty?
        end
        items
      end

      def version
        get('/version')
      end

      private

      def esc(s)
        URI.encode_www_form_component(s.to_s).gsub('+', '%20')
      end

      def retry_delay(res, attempts)
        after = res['Retry-After'].to_i
        after.positive? ? [after, 10].min : attempts
      end

      def build_request(verb, path, body, content_type, accept)
        klass = Net::HTTP.const_get(verb.to_s.capitalize)
        req = klass.new(path)
        req['Accept'] = accept
        req['User-Agent'] = 'k8s_core (openvox)'
        tok = bearer_token
        req['Authorization'] = "Bearer #{tok}" if tok
        if body
          req['Content-Type'] = content_type
          req.body = body.is_a?(String) ? body : JSON.generate(body)
        end
        req
      end

      def bearer_token
        return exec_credential['token'] if @exec
        return @token if @token && !@token_file

        if @token_file
          mtime = File.mtime(@token_file)
          if @token_mtime != mtime
            @token = File.read(@token_file).strip
            @token_mtime = mtime
          end
        end
        @token
      end

      # Runs a kubeconfig exec credential plugin (EKS, GKE, AKS, OIDC helpers).
      def exec_credential
        return @exec_cred if @exec_cred && (@exec_cred_expires.nil? || Time.now < @exec_cred_expires - 30)

        env = (@exec['env'] || []).to_h { |e| [e['name'], e['value']] }
        env['KUBERNETES_EXEC_INFO'] = JSON.generate(
          'apiVersion' => @exec['apiVersion'] || 'client.authentication.k8s.io/v1',
          'kind' => 'ExecCredential', 'spec' => { 'interactive' => false }
        )
        cmd = [@exec['command'], *(@exec['args'] || [])]
        out = IO.popen(env, cmd, err: File::NULL, &:read)
        raise Error, "kubeconfig exec plugin #{@exec['command']} failed" unless $CHILD_STATUS.success?

        status = JSON.parse(out)['status'] || {}
        @exec_cred = status
        @exec_cred_expires = status['expirationTimestamp'] ? Time.parse(status['expirationTimestamp']) : nil
        status
      end

      def connection
        return @http if @http&.started?

        http = Net::HTTP.new(@uri.host, @uri.port)
        http.open_timeout = 10
        http.read_timeout = @timeout
        http.keep_alive_timeout = 30
        if @uri.scheme == 'https'
          http.use_ssl = true
          if @insecure
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          else
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            store = OpenSSL::X509::Store.new
            if @ca_data
              pem_certs(@ca_data).each { |c| store.add_cert(c) }
            elsif @ca_file
              store.add_file(@ca_file)
            else
              store.set_default_paths
            end
            http.cert_store = store
          end
          cert_data = @client_cert_data || (@exec && exec_credential['clientCertificateData'])
          key_data = @client_key_data || (@exec && exec_credential['clientKeyData'])
          if cert_data && key_data
            http.cert = OpenSSL::X509::Certificate.new(cert_data)
            http.key = OpenSSL::PKey.read(key_data)
          end
        end
        http.start
        @http = http
      end

      def reset_connection
        close
      end

      def pem_certs(pem)
        pem.scan(%r{-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----}m).map { |c| OpenSSL::X509::Certificate.new(c) }
      end

      def aggregated_discovery
        accept = 'application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList,application/json;q=0.9'
        map = {}
        ['/api', '/apis'].each do |path|
          doc = get(path, accept: accept)
          return nil unless doc['kind'] == 'APIGroupDiscoveryList'

          (doc['items'] || []).each do |group|
            gname = group.dig('metadata', 'name').to_s
            (group['versions'] || []).each do |v|
              gv = gname.empty? ? v['version'] : "#{gname}/#{v['version']}"
              (v['resources'] || []).each do |r|
                kind = r.dig('responseKind', 'kind')
                next if kind.nil? || kind.empty?

                map["#{gv}/#{kind}"] ||= { 'plural' => r['resource'], 'namespaced' => r['scope'] == 'Namespaced',
                                           'verbs' => r['verbs'] || [], }
              end
            end
          end
        end
        map
      rescue ApiError
        nil
      end

      def legacy_discovery
        map = {}
        gvs = get('/api')['versions'] || []
        (get('/apis')['groups'] || []).each do |g|
          (g['versions'] || []).each { |v| gvs << v['groupVersion'] }
        end
        gvs.each do |gv|
          base = gv.include?('/') ? "/apis/#{gv}" : "/api/#{gv}"
          begin
            (get(base)['resources'] || []).each do |r|
              next if r['name'].include?('/')

              map["#{gv}/#{r['kind']}"] ||= { 'plural' => r['name'], 'namespaced' => r['namespaced'],
                                              'verbs' => r['verbs'] || [], }
            end
          rescue ApiError
            next
          end
        end
        map
      end
    end
  end
end
