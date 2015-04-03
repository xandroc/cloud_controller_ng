require 'actions/service_binding_delete'
require 'actions/deletion_errors'
require 'actions/locks/deleter_lock'

module VCAP::CloudController
  class ServiceInstanceDelete
    def initialize(accepts_incomplete: false, event_repository_opts: {})
      @accepts_incomplete = accepts_incomplete
      @event_repository_opts = event_repository_opts
    end

    def delete(service_instance_dataset)
      service_instance_dataset.each_with_object([]) do |service_instance, errors_accumulator|
        binding_errors = delete_service_bindings(service_instance)
        errors_accumulator.concat binding_errors

        if binding_errors.empty?
          instance_errors = delete_service_instance(service_instance)
          errors_accumulator.concat instance_errors
        end
      end
    end

    private

    def delete_service_instance(service_instance)
      errors = []
      lock = DeleterLock.new(service_instance)
      lock.lock!

      begin
        attributes_to_update, poll_interval = service_instance.client.deprovision(
          service_instance,
          accepts_incomplete: @accepts_incomplete
        )

        if attributes_to_update[:last_operation][:state] == 'succeeded'
          lock.unlock_and_destroy!
        else
          lock.enqueue_unlock!(attributes_to_update, build_fetch_job(poll_interval, service_instance))
        end
      rescue => e
        errors << e
        lock.unlock_and_fail!
      ensure
        lock.unlock_and_fail! if lock.needs_unlock?
      end

      errors
    end

    def delete_service_bindings(service_instance)
      ServiceBindingDelete.new.delete(service_instance.service_bindings_dataset)
    end

    def build_fetch_job(poll_interval, service_instance)
      VCAP::CloudController::Jobs::Services::ServiceInstanceStateFetch.new(
        'service-instance-state-fetch',
        service_instance.client.attrs,
        service_instance.guid,
        @event_repository_opts,
        {},
        poll_interval,
      )
    end
  end
end
