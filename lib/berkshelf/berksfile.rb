module Berkshelf
  # @author Jamie Winsor <jamie@vialstudios.com>
  class Berksfile
    include DSL

    class << self
      def from_file(file)
        content = File.read(file)
        read(content)
      rescue Errno::ENOENT => e
        raise BerksfileNotFound, "No Berksfile or Berksfile.lock found at: #{file}"
      end

      def read(content)
        object = new
        object.instance_eval(content)

        object
      end

      # @param [Array] sources
      #   an array of sources to filter
      # @param [Array, Symbol] excluded
      #   an array of symbols or a symbol representing the group or group(s)
      #   to exclude
      #
      # @return [Array<Berkshelf::CookbookSource>]
      #   an array of sources that are not members of the excluded group(s)
      def filter_sources(sources, excluded)
        excluded = Array(excluded)
        excluded.collect!(&:to_sym)

        sources.select { |source| (excluded & source.groups).empty? }
      end
    end

    attr_reader :locations

    def initialize
      @sources = Hash.new
      @locations = Array.new
    end

    # Add a source of the given name and constraint to the array of sources.
    #
    # @param [String] name
    #   the name of the source to add
    # @param [String, Solve::Constraint] constraint
    #   the constraint to lock the source to
    # @param [Hash] options
    #
    # @raise [DuplicateSourceDefined] if a source is added whose name conflicts
    #   with a source who has already been added.
    #
    # @return [Array<Berkshelf::CookbookSource]
    def add_source(name, constraint = nil, options = {})
      if has_source?(name)
        raise DuplicateSourceDefined, "Berksfile contains two sources named '#{name}'. Remove one and try again."
      end

      options[:constraint] = constraint

      @sources[name] = CookbookSource.new(name, options)
    end

    # Create a location hash and add it to the end of the array of locations.
    #
    # subject.add_location(:chef_api, "http://chef:8080", node_name: "reset", client_key: "/Users/reset/.chef/reset.pem") =>
    #   [ { type: :chef_api, value: "http://chef:8080/", node_name: "reset", client_key: "/Users/reset/.chef/reset.pem" } ]
    #
    # @param [Symbol] type
    # @param [String, Symbol] value
    # @param [Hash] options
    #
    # @return [Hash]
    def add_location(type, value, options = {})
      locations.push(type: type, value: value, options: options)
    end

    # @param [#to_s] source
    #   the source to remove
    #
    # @return [Berkshelf::CookbookSource]
    def remove_source(source)
      @sources.delete(source.to_s)
    end

    # @param [#to_s] source
    #   the source to check presence of
    #
    # @return [Boolean]
    def has_source?(source)
      @sources.has_key?(source.to_s)
    end

    # @option options [Symbol, Array] :exclude 
    #   Group(s) to exclude to exclude from the returned Array of sources
    #   group to not be installed
    #
    # @return [Array<Berkshelf::CookbookSource>]
    def sources(options = {})
      l_sources = @sources.collect { |name, source| source }.flatten

      if options[:exclude]
        self.class.filter_sources(l_sources, options[:exclude])
      else
        l_sources
      end
    end

    # @return [Hash]
    #   a hash containing group names as keys and an array of CookbookSources
    #   that are a member of that group as values
    #
    #   Example:
    #     {
    #       nautilus: [
    #         #<Berkshelf::CookbookSource @name="nginx">,
    #         #<Berkshelf::CookbookSource @name="mysql">,
    #       ],
    #       skarner: [
    #         #<Berkshelf::CookbookSource @name="nginx">
    #       ]
    #     }
    def groups
      {}.tap do |groups|
        sources.each do |source|
          source.groups.each do |group|
            groups[group] ||= []
            groups[group] << source
          end
        end
      end
    end

    # @param [String] name
    #   name of the source to return
    #
    # @return [Berkshelf::CookbookSource]
    def [](name)
      @sources[name]
    end
    alias_method :get_source, :[]

    # @option options [Symbol, Array] :without 
    #   Group(s) to exclude which will cause any sources marked as a member of the 
    #   group to not be installed
    # @option options [String, Pathname] :shims
    #   Path to a directory of shims each pointing to a Cookbook Version that is
    #   part of the dependency solution. Each shim is a hard link on disk.
    def install(options = {})
      resolver = Resolver.new(
        Berkshelf.downloader,
        sources: sources(exclude: options[:without]),
        locations: locations
      )

      solution = resolver.resolve
      if options[:shims]
        write_shims(options[:shims], solution)
        Berkshelf.ui.info "Shims written to: '#{options[:shims]}'"
      end
      write_lockfile(resolver.sources) unless lockfile_present?
    end

    # @param [String] chef_server_url
    #   the full URL to the Chef Server to upload to
    #
    #     "https://api.opscode.com/organizations/vialstudios"
    #
    # @option options [Symbol, Array] :without 
    #   Group(s) to exclude which will cause any sources marked as a member of the 
    #   group to not be installed
    # @option options [String] :node_name
    #   the name of the client used to sign REST requests to the Chef Server
    # @option options [String] :client_key
    #   the filepath location for the client's key used to sign REST requests
    #   to the Chef Server
    # @option options [Boolean] :force Upload the Cookbook even if the version 
    #   already exists and is frozen on the target Chef Server
    # @option options [Boolean] :freeze Freeze the uploaded Cookbook on the Chef 
    #   Server so that it cannot be overwritten
    def upload(chef_server_url, options = {})
      uploader = Uploader.new(chef_server_url, options)
      solution = resolve(options)

      solution.each do |cb|
        Berkshelf.ui.info "Uploading #{cb.cookbook_name} (#{cb.version}) to: '#{chef_server_url}'"
        uploader.upload!(cb, options)
      end
    end

    # Finds a solution for the Berksfile and returns an array of CachedCookbooks.
    #
    # @option options [Symbol, Array] :without 
    #   Group(s) to exclude which will cause any sources marked as a member of the 
    #   group to not be resolved
    #
    # @return [Array<Berkshelf::CachedCookbooks]
    def resolve(options = {})
      Resolver.new(
        Berkshelf.downloader,
        sources: sources(exclude: options[:without]),
        locations: locations
      ).resolve
    end

    # Write a collection of hard links to the given path representing the given
    # CachedCookbooks. Useful for getting Cookbooks in a single location for 
    # consumption by Vagrant, or another tool that expect this structure.
    #
    # @example 
    #   Given the path: '/Users/reset/code/pvpnet/cookbooks'
    #   And a CachedCookbook: 'nginx' verison '0.100.5' at '/Users/reset/.berkshelf/nginx-0.100.5'
    #
    #   A hardlink will be created at: '/Users/reset/code/pvpnet/cookbooks/nginx'
    #
    # @param [Pathname, String] path
    # @param [Array<Berkshelf::CachedCookbook>] cached_cookbooks
    def write_shims(path, cached_cookbooks)
      actual_path = nil

      if descendant_directory?(path, Dir.pwd)
        actual_path = path
        FileUtils.rm_rf(actual_path)
        path = File.join(Berkshelf.tmp_dir, "shims")
      end

      FileUtils.mkdir_p(path)
      cached_cookbooks.each do |cached_cookbook|
        destination = File.expand_path(File.join(path, cached_cookbook.cookbook_name))
        FileUtils.rm_rf(destination)
        FileUtils.ln_r(cached_cookbook.path, destination, force: true)
      end

      if actual_path
        FileUtils.mv(path, actual_path)
      end
    end

    private

      def descendant_directory?(candidate, parent)
        hack = FileUtils::Entry_.new('/tmp')
        hack.send(:descendant_diretory?, candidate, parent)
      end

      def lockfile_present?
        File.exist?(Berkshelf::Lockfile::DEFAULT_FILENAME)
      end

      def write_lockfile(sources)
        Berkshelf::Lockfile.new(sources).write
      end
  end
end
