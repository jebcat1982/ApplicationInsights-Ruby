require_relative 'sender_base'
require 'thread'

module ApplicationInsights
  module Channel
    # An asynchronous sender that works in conjunction with the {AsynchronousQueue}. The sender object will start a
    # worker thread that will pull items from the {#queue}. The thread will be created when the client calls {#start} and
    # will check for queue items every {#send_interval} seconds. The worker thread can also be forced to check the queue
    # by setting the {AsynchronousQueue#flush_notification} event.
    #
    # - If no items are found, the thread will go back to sleep.
    # - If items are found, the worker thread will send items to the specified service in batches of {#send_buffer_size}.
    #
    # If no queue items are found for {#send_time} seconds,  the worker thread will shut down (and {#start} will
    # need  to be called again).
    class AsynchronousSender < SenderBase
      # Initializes a new instance of the class.
      # @param [String] service_endpoint_uri the address of the service to send telemetry data to.
      def initialize(service_endpoint_uri='https://dc.services.visualstudio.com/v2/track')
        @send_interval = 1.0
        @send_remaining_time = 0
        @send_time = 3.0
        @lock_work_thread = Mutex.new
        @work_thread = nil
        @start_notification_processed = true
        super service_endpoint_uri
      end

      # The time span in seconds at which the the worker thread will check the {#queue} for items (defaults to: 1.0).
      # @return [Fixnum] the interval in seconds.
      attr_accessor :send_interval

      # The time span in seconds for which the worker thread will stay alive if no items are found in the {#queue} (defaults to 3.0).
      # @return [Fixnum] the interval in seconds.
      attr_accessor :send_time

      # The worker thread which checks queue items and send data every (#send_interval) seconds or upon flush.
      # @return [Thread] the work thread
      attr_reader :work_thread

      # Calling this method will create a worker thread that checks the {#queue} every {#send_interval} seconds for
      # a total duration of {#send_time} seconds for new items. If a worker thread has already been created, calling
      # this method does nothing.
      def start
        @start_notification_processed = false
        # Maintain one working thread at one time
        if !@work_thread
          @lock_work_thread.synchronize do
            if !@work_thread
              local_send_interval = (@send_interval < 0.1) ? 0.1 : @send_interval
              @send_remaining_time = (@send_time < local_send_interval) ? local_send_interval : @send_time
              @work_thread = Thread.new do
                run
              end
              @work_thread.abort_on_exception = false
            end
          end
        end
      end

      private

      def run
        # save the queue locally
        local_queue = @queue
        if local_queue == nil
          @work_thread = nil
          return
        end

        begin
        # fix up the send interval (can't be lower than 100ms)
        local_send_interval = (@send_interval < 0.1) ? 0.1 : @send_interval
        while TRUE
          @start_notification_processed = true
          while TRUE
            # get at most @send_buffer_size items from the queue
            counter = @send_buffer_size
            data = []
            while counter > 0
              item = local_queue.pop
              break if not item
              data.push item
              counter -= 1
            end

            # if we didn't get any items from the queue, we're done here
            break if data.length == 0

            # reset the send time
            @send_remaining_time = @send_time

            # finally send the data
            send data
          end

          # wait at most @send_interval ms (or until we get signalled)
          result = local_queue.flush_notification.wait local_send_interval
          if result
            local_queue.flush_notification.clear
            next
          end

          # decrement the remaining time
          @send_remaining_time -= local_send_interval
          # If remaining time <=0 and there is no start notification unprocessed, then stop the working thread
          if @send_remaining_time <= 0 && @start_notification_processed
            # Note: there is still a chance some start notification could be missed, e.g., the start method
            # got triggered between the above and following line. However the data is not lost as it would be processed
            # later when next start notification comes after the worker thread stops.  The cost to ensure no
            # notification miss is high where a lock is required each time the start method calls.
            @work_thread = nil
            break
          end
        end
        rescue
          # Make sure work_thread sets to nil when it terminates abnormally
          @work_thread = nil
        end
      end
    end
  end
end