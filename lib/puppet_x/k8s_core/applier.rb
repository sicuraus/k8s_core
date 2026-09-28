# frozen_string_literal: true

require_relative '../k8s_core'

module PuppetX
  module K8sCore
    # Server-side apply with dry-run drift detection, shared by the
    # k8s_resource and k8s_patch providers.
    #
    # Including providers implement #desired_body and may override
    # #force_conflicts?.
    module Applier
      def client
        PuppetX::K8sCore.client
      end

      def api_version
        resource[:api_version]
      end

      def kind
        resource[:kind]
      end

      def namespace
        resource[:namespace]
      end

      def object_name
        resource[:resource_name]
      end

      def object_ref
        "#{kind} #{"#{namespace}/" if namespace}#{object_name}"
      end

      def noop?
        Puppet[:noop] || resource.noop?
      end

      def force_conflicts?
        false
      end

      # Resolves the kind; waits for a CRD applied earlier in this run to be
      # served. In noop runs a kind that is not served yet reads as absent.
      def kind_info
        return @kind_info if @kind_info

        @kind_info = client.resource_info(api_version, kind)
        return @kind_info if @kind_info
        return nil if noop?

        @kind_info = client.wait_for_kind(api_version, kind, timeout: 60)
      end

      def live
        return @live if defined?(@live)

        @live = if kind_info.nil?
                  resource.warning("#{api_version} #{kind} is not served yet; treating #{object_ref} as absent")
                  nil
                else
                  client.get_object(api_version, kind, namespace, object_name)
                end
      end

      def forget_live
        remove_instance_variable(:@live) if defined?(@live)
      end

      def base_body
        md = { 'name' => object_name }
        md['namespace'] = namespace if namespace
        { 'apiVersion' => api_version, 'kind' => kind, 'metadata' => md }
      end

      def drift_managers
        Array(resource[:drift_managers] || DEFAULT_DRIFT_MANAGERS)
      end

      def drift_manager?(name)
        drift_managers.any? { |pat| File.fnmatch?(pat, name) }
      end

      # Server-side apply. A conflict with an imperative edit (kubectl edit,
      # patch, scale...) is drift and is taken back; a conflict with any other
      # field manager (a controller, Helm, Argo, an operator) fails unless
      # force_conflicts is set, naming the manager.
      def ssa(body, dry_run:)
        client.apply(body, field_manager: resource[:field_manager], force: force_conflicts?, dry_run: dry_run)
      rescue ApiError => e
        raise unless e.conflict?

        managers = e.conflict_managers
        if !managers.empty? && managers.all? { |m| drift_manager?(m) }
          @reclaimed_from = managers
          return client.apply(body, field_manager: resource[:field_manager], force: true, dry_run: dry_run)
        end
        who = managers.empty? ? 'another field manager' : managers.join(', ')
        raise Error, "#{object_ref}: fields are owned by #{who}; not forcing (set force_conflicts => true to take " \
                     "ownership). #{e.status&.dig('message') || e.message}"
      end

      # True when a server-side dry-run of the desired body leaves the live
      # object unchanged. Remembers the differences for the change message.
      def body_insync?(body)
        return true if live.nil?

        dry = ssa(body, dry_run: true)
        @changes = Object.diff(Object.normalize(live), Object.normalize(dry))
        @changes.empty?
      end

      def change_summary
        return "applied #{object_ref}" if @changes.nil? || @changes.empty?

        msg = "#{object_ref}: #{Object.summarize_changes(kind, @changes)}"
        msg += " (reverting edits by #{@reclaimed_from.join(', ')})" if @reclaimed_from
        msg
      end

      def apply_body(body)
        result = ssa(body, dry_run: false)
        @live = result
        result
      end

      def wait_until_ready(timeout)
        deadline = Time.now + timeout
        reason = nil
        loop do
          obj = client.get_object(api_version, kind, namespace, object_name)
          raise Error, "#{object_ref} disappeared while waiting for readiness" if obj.nil?

          ready, reason = Object.ready(obj)
          return true if ready

          if noop?
            resource.notice("#{object_ref} is not ready (#{reason})")
            return false
          end
          raise Error, "#{object_ref} not ready after #{timeout}s: #{reason}" if Time.now > deadline

          Puppet.debug("#{object_ref}: waiting (#{reason})")
          sleep 2
        end
      end

      def wait_until_gone(timeout)
        deadline = Time.now + timeout
        loop do
          return true if client.get_object(api_version, kind, namespace, object_name).nil?
          raise Error, "#{object_ref} still present #{timeout}s after deletion" if Time.now > deadline

          sleep 2
        end
      end
    end
  end
end
