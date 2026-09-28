# frozen_string_literal: true

require 'json'

module PuppetX
  module K8sCore
    # Label and annotation keys follow the openvox-operator API group.
    LABEL_PREFIX = 'openvox.voxpupuli.org'
    MANAGED_BY = "#{LABEL_PREFIX}/managed-by"
    TITLE_ANNOTATION = "#{LABEL_PREFIX}/title"
    PRUNE_ANNOTATION = "#{LABEL_PREFIX}/prune"
    INVENTORY_LABEL = "#{LABEL_PREFIX}/inventory"
    INVENTORY_KEY = 'inventory.json'

    # API groups without a ".k8s.io" suffix that are still built in.
    BUILTIN_GROUPS = %w[apps batch policy autoscaling].freeze

    LABEL_VALUE = %r{\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z}.freeze

    # Metadata the API server maintains; never part of a comparison.
    SERVER_METADATA = %w[managedFields resourceVersion generation creationTimestamp uid selfLink].freeze

    REDACTED = '[redacted]'

    # Field managers whose conflicting fields are drift to correct, not
    # another owner to respect: imperative kubectl edits.
    DEFAULT_DRIFT_MANAGERS = ['kubectl*', 'before-first-apply'].freeze

    # Helpers for titles, object bodies and comparisons.
    module Object
      module_function

      # "Kind/name" or "Kind/namespace/name" => [kind, namespace, name]
      def parse_title(title)
        parts = title.to_s.split('/', -1)
        case parts.size
        when 2 then [parts[0], nil, parts[1]]
        when 3 then parts
        else [nil, nil, nil]
        end
      end

      def format_title(kind, namespace, name)
        namespace.to_s.empty? ? "#{kind}/#{name}" : "#{kind}/#{namespace}/#{name}"
      end

      def title_for(doc)
        md = doc['metadata'] || {}
        format_title(doc['kind'], md['namespace'], md['name'])
      end

      def group_of(api_version)
        api_version.to_s.include?('/') ? api_version.split('/').first : ''
      end

      # Identity used for inventories: group, kind, namespace, name.
      def key(api_version, kind, namespace, name)
        [group_of(api_version), kind, namespace.to_s, name].join('|')
      end

      def deep_merge(a, b)
        return b unless a.is_a?(Hash) && b.is_a?(Hash)

        a.merge(b) { |_k, x, y| deep_merge(x, y) }
      end

      def deep_dup(o)
        JSON.parse(JSON.generate(o))
      end

      # Puppet hands us hashes that may carry symbols or Puppet-internal
      # values; round-trip through JSON so the body is plain data.
      def plain(o)
        case o
        when Hash then o.each_with_object({}) { |(k, v), h| h[k.to_s] = plain(v) }
        when Array then o.map { |v| plain(v) }
        when Symbol then (o == :undef) ? nil : o.to_s
        else o.respond_to?(:unwrap) ? plain(o.unwrap) : o
        end
      end

      # Strips status and server-maintained metadata for comparison.
      def normalize(obj)
        o = deep_dup(obj || {})
        o.delete('status')
        md = o['metadata'] || {}
        SERVER_METADATA.each { |k| md.delete(k) }
        o
      end

      # [[path, old, new], ...] for every leaf that differs.
      def diff(old, new, path = '')
        if old.is_a?(Hash) && new.is_a?(Hash)
          (old.keys | new.keys).sort.flat_map do |k|
            diff(old[k], new[k], path.empty? ? k.to_s : "#{path}.#{k}")
          end
        elsif old.is_a?(Array) && new.is_a?(Array) && old.size == new.size
          old.each_index.flat_map { |i| diff(old[i], new[i], "#{path}[#{i}]") }
        elsif old == new
          []
        else
          [[path, old, new]]
        end
      end

      # The part of `live` that `desired` talks about, for readable reports.
      def project(live, desired)
        if desired.is_a?(Hash) && live.is_a?(Hash)
          desired.keys.each_with_object({}) do |k, h|
            h[k] = project(live[k], desired[k]) if live.key?(k)
          end
        elsif desired.is_a?(Array) && live.is_a?(Array)
          live.each_with_index.map { |v, i| (i < desired.size) ? project(v, desired[i]) : v }
        else
          live
        end
      end

      # True when every leaf in `subset` has the same value in `obj`.
      def subset?(subset, obj)
        case subset
        when Hash
          obj.is_a?(Hash) && subset.all? { |k, v| obj.key?(k) ? subset?(v, obj[k]) : v.nil? }
        when Array
          obj.is_a?(Array) && subset.size == obj.size && subset.each_index.all? { |i| subset?(subset[i], obj[i]) }
        else
          subset == obj
        end
      end

      def secret?(kind)
        kind.to_s == 'Secret'
      end

      def redact_path?(kind, path)
        secret?(kind) && path.match?(%r{\A(data|stringData)(\.|\z)})
      end

      def summarize_changes(kind, changes, limit: 20)
        lines = changes.first(limit).map do |path, old, new|
          if redact_path?(kind, path)
            "#{path} changed #{REDACTED}"
          elsif old.nil?
            "#{path} added #{fmt(new)}"
          elsif new.nil?
            "#{path} removed (was #{fmt(old)})"
          else
            "#{path}: #{fmt(old)} -> #{fmt(new)}"
          end
        end
        lines << "... and #{changes.size - limit} more" if changes.size > limit
        lines.join('; ')
      end

      def fmt(v)
        s = v.is_a?(String) ? v.inspect : JSON.generate(v)
        (s.size > 120) ? "#{s[0, 117]}..." : s
      end

      # ---- readiness ------------------------------------------------------

      def condition(obj, type)
        (obj.dig('status', 'conditions') || []).find { |c| c['type'] == type }
      end

      def condition_true?(obj, type)
        condition(obj, type)&.fetch('status', nil) == 'True'
      end

      def observed_current?(obj)
        gen = obj.dig('metadata', 'generation')
        obs = obj.dig('status', 'observedGeneration')
        gen.nil? || (obs && obs >= gen)
      end

      # Built-in readiness rules. Returns [ready, reason]; raises on terminal failure.
      def ready(obj)
        st = obj['status'] || {}
        spec = obj['spec'] || {}
        case obj['kind']
        when 'Deployment'
          want = spec.fetch('replicas', 1)
          return [false, 'rollout not observed yet'] unless observed_current?(obj)
          if (c = condition(obj, 'Progressing')) && c['reason'] == 'ProgressDeadlineExceeded'
            raise Error, "rollout stalled: #{c['message']}"
          end
          return [false, "#{st['updatedReplicas'].to_i}/#{want} replicas updated"] if st['updatedReplicas'].to_i < want
          return [false, "#{st['replicas'].to_i - st['updatedReplicas'].to_i} old replicas pending termination"] if st['replicas'].to_i > st['updatedReplicas'].to_i
          return [false, "#{st['availableReplicas'].to_i}/#{want} replicas available"] if st['availableReplicas'].to_i < want

          [true, "#{want} replicas available"]
        when 'StatefulSet'
          want = spec.fetch('replicas', 1)
          return [false, 'rollout not observed yet'] unless observed_current?(obj)
          return [false, "#{st['readyReplicas'].to_i}/#{want} replicas ready"] if st['readyReplicas'].to_i < want

          if spec.dig('updateStrategy', 'type') != 'OnDelete'
            return [false, "#{st['updatedReplicas'].to_i}/#{want} replicas updated"] if st['updatedReplicas'].to_i < want
            return [false, 'revision update in progress'] if st['updateRevision'] && st['currentRevision'] != st['updateRevision']
          end
          [true, "#{want} replicas ready"]
        when 'DaemonSet'
          return [false, 'rollout not observed yet'] unless observed_current?(obj)

          want = st['desiredNumberScheduled'].to_i
          return [false, "#{st['updatedNumberScheduled'].to_i}/#{want} pods updated"] if st['updatedNumberScheduled'].to_i < want
          return [false, "#{st['numberAvailable'].to_i}/#{want} pods available"] if st['numberAvailable'].to_i < want

          [true, "#{want} pods available"]
        when 'Job'
          raise Error, "job failed: #{condition(obj, 'Failed')['message']}" if condition_true?(obj, 'Failed')

          condition_true?(obj, 'Complete') ? [true, 'complete'] : [false, 'not complete']
        when 'CustomResourceDefinition'
          condition_true?(obj, 'Established') ? [true, 'established'] : [false, 'not established']
        when 'Pod'
          raise Error, 'pod failed' if st['phase'] == 'Failed'
          return [true, 'succeeded'] if st['phase'] == 'Succeeded'

          condition_true?(obj, 'Ready') ? [true, 'ready'] : [false, "phase #{st['phase'] || 'unknown'}"]
        when 'PersistentVolumeClaim'
          (st['phase'] == 'Bound') ? [true, 'bound'] : [false, "phase #{st['phase'] || 'unknown'}"]
        when 'Namespace'
          (st['phase'] == 'Active') ? [true, 'active'] : [false, "phase #{st['phase'] || 'unknown'}"]
        else
          return [false, 'status not observed yet'] unless observed_current?(obj)
          return [true, 'no Ready condition'] unless condition(obj, 'Ready')

          condition_true?(obj, 'Ready') ? [true, 'Ready'] : [false, condition(obj, 'Ready')['message'] || 'not Ready']
        end
      end

      # ---- JSONPath subset --------------------------------------------------
      #
      # Supports what `kubectl wait --for=jsonpath=` is typically used for:
      # {.a.b}, {.a[0].b}, {.a[?(@.type=="Ready")].status}.

      def jsonpath(obj, expr)
        e = expr.to_s.strip
        e = e[1..-2] if e.start_with?('{') && e.end_with?('}')
        e = e.sub(%r{\A\$?\.?}, '')
        cur = [obj]
        e.scan(%r{\[\?\(@\.([\w.-]+)\s*==\s*["']?([^"')]*)["']?\)\]|\[(\d+|\*)\]|([^.\[\]]+)}).each do |fk, fv, idx, name|
          cur = cur.flat_map do |c|
            if fk
              c.is_a?(Array) ? c.select { |i| i.is_a?(Hash) && i.dig(*fk.split('.')).to_s == fv } : []
            elsif idx
              next [] unless c.is_a?(Array)

              (idx == '*') ? c : [c[idx.to_i]].compact
            else
              (c.is_a?(Hash) && c.key?(name)) ? [c[name]] : []
            end
          end
        end
        cur
      end
    end
  end
end
