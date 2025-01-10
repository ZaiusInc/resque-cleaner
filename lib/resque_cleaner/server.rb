require 'yaml'
require 'cgi'

# Extends Resque Web Based UI.
# Structure has been borrowed from ResqueScheduler.
module ResqueCleaner
  module Server
    def self.erb_path(filename)
      File.join(File.dirname(__FILE__), 'server', 'views', filename)
    end

    # Pagination helper for list page.
    class Paginate
      DEFAULT_PAGE_SIZE = 20
      attr_accessor :page_size, :page, :jobs, :url
      def initialize(jobs, url, page = 1, page_size = DEFAULT_PAGE_SIZE)
        @jobs = jobs
        @url = url
        @page = !page || page < 1 ? 1 : page
        @page_size = page_size.positive? ? page_size : DEFAULT_PAGE_SIZE
      end

      def first_index
        @page_size * (@page - 1)
      end

      def last_index
        last = first_index + @page_size - 1
        last > @jobs.size - 1 ? @jobs.size - 1 : last
      end

      def paginated_jobs
        @jobs[first_index, @page_size]
      end

      def first_page?
        @page <= 1
      end

      def last_page?
        @page >= max_page
      end

      def page_url(page)
        u = @url
        u += @url.include?('?') ? '&' : '?'
        if page.is_a?(Symbol)
          page = @page - 1 if page == :prev
          page = @page + 1 if page == :next
        end
        u + "p=#{page}"
      end

      def total_size
        @jobs.size
      end

      def max_page
        ((total_size - 1) / @page_size) + 1
      end
    end

    def self.included(base)
      base.class_eval do
        helpers do
          def time_filter(id, name, value)
            html = "<select id=\"#{id}\" name=\"#{name}\">"
            html += '<option value="">-</option>'
            [1, 3, 6, 12, 24].each do |h|
              selected = h.to_s == value ? 'selected="selected"' : ''
              html += "<option #{selected} value=\"#{h}\">#{h} #{h == 1 ? 'hour' : 'hours'} ago</option>"
            end
            [3, 7, 14, 28].each do |d|
              selected = (d * 24).to_s == value ? 'selected="selected"' : ''
              html += "<option #{selected} value=\"#{d * 24}\">#{d} days ago</option>"
            end
            html + '</select>'
          end

          def simple_select(id, name, options, value)
            html = "<select id=\"#{id}\" name=\"#{name}\">"
            html += '<option value="">-</option>'
            options.each do |option|
              selected = option == value ? 'selected="selected"' : ''
              html += "<option #{selected} value=\"#{option}\">#{option}</option>"
            end
            html + '</select>'
          end

          def show_job_args(args)
            # Same format as resque gem
            Array(args).map(&:to_yaml).join("\n")
          rescue
            # Binary
            args.to_s
          end

          def text_filter(id, name, value)
            html = "<input id=\"#{id}\"  type=\"text\" name=\"#{name}\" value=\"#{value}\">"
            html + '</input>'
          end

          def job_sha(job)
            Digest::SHA1.hexdigest(job.to_json)
          rescue
            # Binary
            Digest::SHA1.hexdigest(job.to_s)
          end
        end

        mime_type :json, 'application/json'

        get '/cleaner' do
          load_library
          load_cleaner_filter

          @jobs = cleaner.select
          @stats = { klass: {}, exception: {}, queue: {}, queue_class: {} }
          @total = Hash.new(0)
          @jobs.each do |job|
            payload = job['payload'] || {}
            klass = payload['class'] || 'UNKNOWN'
            exception = job['exception'] || 'UNKNOWN'
            queue = job['queue'] || 'UNKNOWN'
            failed_at = Time.parse job['failed_at']
            queue_klass = "#{queue}-#{klass}"
            @stats[:klass][klass] ||= Hash.new(0)
            @stats[:exception][exception] ||= Hash.new(0)
            @stats[:queue][queue] ||= Hash.new(0)
            @stats[:queue_class][queue_klass] ||= Hash.new(0)
            [
              @stats[:klass][klass],
              @stats[:exception][exception],
              @stats[:queue][queue],
              @stats[:queue_class][queue_klass],
              @total
            ].each do |stat|
              stat[:total] += 1
              stat[:h1] += 1 if failed_at >= hours_ago(1)
              stat[:h3] += 1 if failed_at >= hours_ago(3)
              stat[:d1] += 1 if failed_at >= hours_ago(24)
              stat[:d3] += 1 if failed_at >= hours_ago(24 * 3)
              stat[:d7] += 1 if failed_at >= hours_ago(24 * 7)
            end
          end

          erb File.read(ResqueCleaner::Server.erb_path('cleaner.erb'))
        end

        get '/cleaner_list' do
          load_library
          load_cleaner_filter
          build_urls

          block = filter_block

          @failed = cleaner.select(&block).reverse

          @paginate = Paginate.new(@failed, @list_url, params[:p].to_i)

          @klasses = cleaner.stats_by_class.keys
          @exceptions = cleaner.stats_by_exception.keys
          @queues = cleaner.stats_by_queue.keys
          @count = cleaner.select(&block).size

          erb File.read(ResqueCleaner::Server.erb_path('cleaner_list.erb'))
        end

        post '/cleaner_exec' do
          load_library
          load_cleaner_filter
          build_urls

          if params[:select_all_pages] != '1'
            @sha1 = {}
            params[:sha1].split(',').each { |s| @sha1[s] = true }
          end

          block = filter_block

          @count =
            case params[:action]
            when 'clear' then cleaner.clear(&block)
            when 'retry_and_clear' then cleaner.requeue(true, &block)
            when 'retry' then cleaner.requeue(false, {}, &block)
            end

          erb File.read(ResqueCleaner::Server.erb_path('cleaner_exec.erb'))
        end

        get '/cleaner_dump' do
          load_library
          load_cleaner_filter

          block = filter_block

          content_type :json
          JSON.pretty_generate(cleaner.select(&block))
        end

        post '/cleaner_stale' do
          load_library
          cleaner.clear_stale
          redirect url_path(:cleaner)
        end
      end
    end

    def cleaner
      @cleaner ||= Resque::Plugins::ResqueCleaner.new
      @cleaner.print_message = false
      @cleaner
    end

    def load_library
      require 'digest/sha1'
      begin
        require 'yajl/json_gem' unless [].respond_to?(:to_json)
      rescue Exception
        require 'json'
      end
    end

    def load_cleaner_filter
      @from = params[:f] == '' ? nil : params[:f]
      @to = params[:t] == '' ? nil : params[:t]
      @klass = params[:c] == '' ? nil : params[:c]
      @exception = params[:ex] == '' ? nil : params[:ex]
      @queue = params[:queue] == '' ? nil : params[:queue]
      @regex = params[:regex] == '' ? nil : params[:regex]
    end

    def build_urls
      params = {
        c:     @klass,
        ex:    @exception,
        f:     @from,
        t:     @to,
        regex: @regex,
        queue: @queue
      }.map { |key, value| "#{key}=#{CGI.escape(value.to_s)}" }.join('&')

      @list_url = "cleaner_list?#{params}"
      @dump_url = "cleaner_dump?#{params}"
    end

    def filter_block
      lambda do |j|
        (!@from || j.after?(hours_ago(@from))) &&
          (!@to || j.before?(hours_ago(@to))) &&
          (!@klass || j.klass?(@klass)) &&
          (!@exception || j.exception?(@exception)) &&
          (!@queue || j.queue?(@queue)) &&
          (!@sha1 || @sha1[job_sha(j)]) &&
          (!@regex || j.to_s =~ /#{@regex}/)
      end
    end

    def hours_ago(h)
      Time.now - h.to_i * 60 * 60
    end
    Resque::Server.tabs << 'Cleaner'
  end
end

Resque::Server.class_eval do
  include ResqueCleaner::Server
end
