# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'yaml'

# @summary Renders a vendored Helm chart into Kubernetes objects at compile time.
#
# Runs `helm template` against a chart directory or packaged `.tgz` on the
# compiling host, never a remote repository, so every object is in the
# catalog (which is what makes pruning and reporting complete). Chart hooks
# are rendered as ordinary objects; order them with relationships or
# `k8s_wait` if they matter. Requires `helm` on the PATH of the compiler.
Puppet::Functions.create_function(:'k8s_core::helm_template') do
  # @param chart Path to a chart directory or `.tgz`, e.g. `"${module_path}/charts/ingress-nginx"`.
  # @param values Chart values.
  # @param options `release_name` (default `release`), `namespace`,
  #   `include_crds` (default true), `kube_version`, `api_versions` (Array),
  #   `helm` (path to the binary).
  # @return The rendered objects.
  dispatch :helm_template do
    param 'String[1]', :chart
    optional_param 'Hash', :values
    optional_param 'Hash', :options
    return_type 'Array[Hash]'
  end

  def helm_template(chart, values = {}, options = {})
    raise Puppet::ParseError, "k8s_core::helm_template: #{chart} is not a local chart; vendor charts into the control repo" if chart.match?(%r{\A[a-z][a-z0-9+.-]*://}i) || !File.exist?(chart)

    Tempfile.create(['values', '.yaml']) do |f|
      f.write(YAML.dump(values))
      f.flush
      cmd = [options['helm'] || 'helm', 'template', options['release_name'] || 'release', chart, '--values', f.path]
      cmd += ['--namespace', options['namespace']] if options['namespace']
      cmd << '--include-crds' unless options['include_crds'] == false
      cmd += ['--kube-version', options['kube_version']] if options['kube_version']
      Array(options['api_versions']).each { |v| cmd += ['--api-versions', v] }
      out = Puppet::Util::Execution.execute(cmd, failonfail: true, combine: false)
      call_function('k8s_core::yaml_documents', out.to_s)
    end
  rescue Puppet::ExecutionFailure => e
    raise Puppet::ParseError, "k8s_core::helm_template: #{e.message}"
  end
end
