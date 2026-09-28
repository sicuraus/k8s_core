# frozen_string_literal: true

require 'yaml'

# @summary Splits multi-document YAML into Kubernetes objects.
#
# Empty documents are dropped and `kind: List` documents are expanded, so the
# result is one hash per object, ready for `k8s_core::documents` or
# `k8s_resource`. Only plain YAML types are allowed (no aliases or tags).
Puppet::Functions.create_function(:'k8s_core::yaml_documents') do
  # @param yaml Multi-document YAML, e.g. from `file()` or `epp()`.
  # @return The objects, in document order.
  dispatch :yaml_documents do
    param 'String', :yaml
    return_type 'Array[Hash]'
  end

  def yaml_documents(yaml)
    docs = YAML.load_stream(yaml).map { |d| d }
    docs.compact.flat_map do |doc|
      raise Puppet::ParseError, "k8s_core::yaml_documents: expected a mapping, got #{doc.class}" unless doc.is_a?(Hash)

      (doc['kind'].to_s.end_with?('List') && doc['items'].is_a?(Array)) ? doc['items'] : [doc]
    end
  rescue Psych::Exception => e
    raise Puppet::ParseError, "k8s_core::yaml_documents: #{e.message}"
  end
end
