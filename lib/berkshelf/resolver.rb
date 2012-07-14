module Berkshelf
  # @author Jamie Winsor <jamie@vialstudios.com>
  class Resolver
    extend Forwardable

    DEFAULT_LOCATIONS = [
      {
        type: :site,
        value: :opscode,
        options: Hash.new
      }
    ].freeze

    attr_reader :graph
    attr_reader :locations

    # @param [Downloader] downloader
    # @param [Hash] options
    #
    # @option options [Array<CookbookSource>, CookbookSource] sources
    # @option options [Array<Hash>] locations
    def initialize(downloader, options = {})
      @downloader = downloader
      @graph = Solve::Graph.new
      @sources = Hash.new
      @locations = options[:locations] || DEFAULT_LOCATIONS

      # Dependencies need to be added AFTER the sources. If they are
      # not, then one of the dependencies of a source that is added
      # may take precedence over an explicitly set source that appears
      # later in the iterator.
      Array(options[:sources]).each do |source|
        add_source(source, false)
      end

      Array(options[:sources]).each do |source|
        add_source_dependencies(source)
      end
    end

    # Add the given source to the collection of sources for this instance
    # of Resolver. By default the dependencies of the given source will also
    # be added as sources to the collection.
    #
    # @param [Berkshelf::CookbookSource] source
    #   source to add
    # @param [Boolean] include_dependencies
    #   adds the dependencies of the given source as sources to the collection of
    #   if true. Dependencies will be ignored if false.
    #
    # @return [Array<CookbookSource>]
    def add_source(source, include_dependencies = true)
      if has_source?(source)
        raise DuplicateSourceDefined, "A source named '#{source.name}' is already present."
      end

      set_source(source)
      use_source(source) || install_source(source)

      graph.artifacts(source.name, source.cached_cookbook.version)
      
      if include_dependencies
        add_source_dependencies(source)
      end

      sources
    end

    # Add the dependencies of the given source as sources in the collection of sources
    # on this instance of Resolver. Any dependencies which already have a source in the
    # collection of sources of the same name will not be added to the collection a second
    # time.
    #
    # @param [CookbookSource] source
    #   source to convert dependencies into sources
    #
    # @return [Array<CookbookSource>]
    def add_source_dependencies(source)
      source.cached_cookbook.dependencies.each do |name, constraint|
        next if has_source?(name)

        add_source(CookbookSource.new(name, constraint: constraint))
      end
    end

    # @return [Array<Berkshelf::CookbookSource>]
    #   an array of CookbookSources that are currently added to this resolver
    def sources
      @sources.collect { |name, source| source }
    end

    # Finds a solution for the currently added sources and their dependencies and
    # returns an array of CachedCookbooks.
    #
    # @return [Array<Berkshelf::CachedCookbook>]
    def resolve
      graph.artifacts.each do |artifact|
        graph.demands(artifact.name)
      end

      solution = Solve.it!(graph)

      [].tap do |cached_cookbooks|
        solution.each do |name, version|
          cached_cookbooks << get_source(name).cached_cookbook
        end
      end
    end

    # @param [CookbookSource, #to_s] source
    #   name of the source to return
    #
    # @return [Berkshelf::CookbookSource]
    def [](source)
      if source.is_a?(CookbookSource)
        source = source.name
      end
      @sources[source.to_s]
    end
    alias_method :get_source, :[]

    # @param [CoobookSource, #to_s] source
    #   the source to test if the resolver has added
    def has_source?(source)
      !get_source(source).nil?
    end

    private

      attr_reader :downloader

      # @param [CookbookSource] source
      def set_source(source)
        @sources[source.name] = source
      end

      # @param [Berkshelf::CookbookSource] source
      #
      # @return [Boolean]
      def install_source(source)
        downloader.download!(source)
        Berkshelf.ui.info "Installing #{source.name} (#{source.cached_cookbook.version}) from #{source.location}"
      end

      # Use the given source to create a constraint solution if the source has been downloaded or can
      # be satisfied by a cached cookbook that is already present in the cookbook store.
      #
      # @note Git location sources which have not yet been downloaded will not be satisfied by a
      #   cached cookbook from the cookbook store.
      #
      # @param [Berkshelf::CookbookSource] source
      #
      # @raise [ConstraintNotSatisfied] if the CachedCookbook does not satisfy the version constraint of
      #   this instance of Location.
      #   contain a cookbook that satisfies the given version constraint of this instance of
      #   CookbookSource.
      #
      # @return [Boolean]
      def use_source(source)        
        if source.downloaded?
          cached = source.cached_cookbook
          source.location.validate_cached(cached)
        else
          if source.location.is_a?(CookbookSource::GitLocation)
            return false
          end

          cached = downloader.cookbook_store.satisfy(source.name, source.version_constraint)
          return false if cached.nil?

          get_source(source).cached_cookbook = cached
        end

        msg = "Using #{cached.cookbook_name} (#{cached.version})"
        msg << " at #{source.location}" if source.location.is_a?(CookbookSource::PathLocation)
        Berkshelf.ui.info msg

        true
      end
  end
end
