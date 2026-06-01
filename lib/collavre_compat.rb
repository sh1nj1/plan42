# frozen_string_literal: true

# Compatibility shim for `USE_COLLAVRE_GEM=true` deployments that load an
# installed `collavre` gem whose API predates a keyword the host app wants
# to pass.
#
# Boot-time config (`storage.yml`, `config/environments/*.rb`, initializers)
# opts into the newer `boot_safe:` keyword on
# `Collavre::IntegrationSettings.fetch` and `Collavre::AwsCredentials.{s3,
# ses_smtp}`. Older gem versions still define those methods but without
# the keyword, so passing it raises
# `ArgumentError: unknown keyword: :boot_safe` during boot — before the
# `defined?` ENV fallback can kick in.
#
# `CollavreCompat.call` drops kwargs the receiver's signature doesn't list,
# preserving the new safety on matched versions and the old (kwarg-less)
# behavior on legacy versions.
#
# Required eagerly from `config/application.rb` so it's defined before any
# boot-time call site (storage.yml ERB, env config) runs.
module CollavreCompat
  module_function

  def call(receiver, method_name, *args, **kwargs)
    params = receiver.method(method_name).parameters
    safe_kwargs =
      if params.any? { |type, _| type == :keyrest }
        kwargs
      else
        accepted = params.filter_map { |type, name| name if %i[key keyreq].include?(type) }
        kwargs.slice(*accepted)
      end
    receiver.public_send(method_name, *args, **safe_kwargs)
  end
end
