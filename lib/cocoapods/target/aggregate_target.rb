require 'cocoapods/xcode/framework_paths'
require 'cocoapods/xcode/xcframework'

module Pod
  # Stores the information relative to the target used to cluster the targets
  # of the single Pods. The client targets will then depend on this one.
  #
  class AggregateTarget < Target
    # Product types where the product's frameworks must be embedded in a host target
    #
    EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES = [:app_extension, :framework, :static_library, :messages_extension,
                                             :watch_extension, :xpc_service].freeze

    # @return [TargetDefinition] the target definition of the Podfile that
    #         generated this target.
    #
    attr_reader :target_definition

    # @return [Pathname] the folder where the client is stored used for
    #         computing the relative paths. If integrating it should be the
    #         folder where the user project is stored, otherwise it should
    #         be the installation root.
    #
    attr_reader :client_root

    # @return [Xcodeproj::Project] the user project that this target will
    #         integrate as identified by the analyzer.
    #
    attr_reader :user_project

    # @return [Array<String>] the list of the UUIDs of the user targets that
    #         will be integrated by this target as identified by the analyzer.
    #
    # @note   The target instances are not stored to prevent editing different
    #         instances.
    #
    attr_reader :user_target_uuids

    # @return [Hash<String, Xcodeproj::Config>] Map from configuration name to
    #         configuration file for the target
    #
    # @note   The configurations are generated by the {TargetInstaller} and
    #         used by {UserProjectIntegrator} to check for any overridden
    #         values.
    #
    attr_reader :xcconfigs

    # @return [Array<PodTarget>] The dependencies for this target.
    #
    attr_reader :pod_targets

    # @return [Array<AggregateTarget>] The aggregate targets whose pods this
    #         target must be able to import, but will not directly link against.
    #
    attr_reader :search_paths_aggregate_targets

    # Initialize a new instance
    #
    # @param [Sandbox] sandbox @see Target#sandbox
    # @param [BuildType] build_type @see Target#build_type
    # @param [Hash{String=>Symbol}] user_build_configurations @see Target#user_build_configurations
    # @param [Array<String>] archs @see Target#archs
    # @param [Platform] platform @see #Target#platform
    # @param [TargetDefinition] target_definition @see #target_definition
    # @param [Pathname] client_root @see #client_root
    # @param [Xcodeproj::Project] user_project @see #user_project
    # @param [Array<String>] user_target_uuids @see #user_target_uuids
    # @param [Hash{String=>Array<PodTarget>}] pod_targets_for_build_configuration @see #pod_targets_for_build_configuration
    #
    def initialize(sandbox, build_type, user_build_configurations, archs, platform, target_definition, client_root,
                   user_project, user_target_uuids, pod_targets_for_build_configuration)
      super(sandbox, build_type, user_build_configurations, archs, platform)
      raise "Can't initialize an AggregateTarget without a TargetDefinition!" if target_definition.nil?
      raise "Can't initialize an AggregateTarget with an abstract TargetDefinition!" if target_definition.abstract?
      @target_definition = target_definition
      @client_root = client_root
      @user_project = user_project
      @user_target_uuids = user_target_uuids
      @pod_targets_for_build_configuration = pod_targets_for_build_configuration
      @pod_targets = pod_targets_for_build_configuration.values.flatten.uniq
      @search_paths_aggregate_targets = []
      @xcconfigs = {}
    end

    # Merges this aggregate target with additional pod targets that are part of embedded aggregate targets.
    #
    # @param  [Hash{String=>Array<PodTarget>}] embedded_pod_targets_for_build_configuration
    #         The pod targets to merge with.
    #
    # @return [AggregateTarget] a new instance of this aggregate target with additional pod targets to be used from
    #         pod targets of embedded aggregate targets.
    #
    def merge_embedded_pod_targets(embedded_pod_targets_for_build_configuration)
      merged = @pod_targets_for_build_configuration.merge(embedded_pod_targets_for_build_configuration) do |_, before, after|
        (before + after).uniq
      end
      AggregateTarget.new(sandbox, build_type, user_build_configurations, archs, platform,
                          target_definition, client_root, user_project, user_target_uuids, merged).tap do |aggregate_target|
        aggregate_target.search_paths_aggregate_targets.concat(search_paths_aggregate_targets).freeze
        aggregate_target.mark_application_extension_api_only if application_extension_api_only
        aggregate_target.mark_build_library_for_distribution if build_library_for_distribution
      end
    end

    def build_settings(configuration_name = nil)
      if configuration_name
        @build_settings[configuration_name] ||
          raise(ArgumentError, "#{self} does not contain a build setting for the #{configuration_name.inspect} configuration, only #{@build_settings.keys.inspect}")
      else
        @build_settings.each_value.first ||
          raise(ArgumentError, "#{self} does not contain any build settings")
      end
    end

    # @return [Boolean] True if the user_target refers to a
    #         library (framework, static or dynamic lib).
    #
    def library?
      # Without a user_project, we can't say for sure
      # that this is a library
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      unless symbol_types.count == 1
        raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}."
      end
      [:framework, :dynamic_library, :static_library].include? symbol_types.first
    end

    # @return [Boolean] True if the user_target's pods are
    #         for an extension and must be embedded in a host,
    #         target, otherwise false.
    #
    def requires_host_target?
      # If we don't have a user_project, then we can't
      # glean any info about how this target is going to
      # be integrated, so return false since we can't know
      # for sure that this target refers to an extension
      # target that would require a host target
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      unless symbol_types.count == 1
        raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}."
      end
      EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES.include?(symbol_types[0])
    end

    # @return [String] the label for the target.
    #
    def label
      target_definition.label.to_s
    end

    # @return [Podfile] The podfile which declares the dependency
    #
    def podfile
      target_definition.podfile
    end

    # @return [Pathname] the path of the user project that this target will
    #         integrate as identified by the analyzer.
    #
    def user_project_path
      user_project.path if user_project
    end

    # List all user targets that will be integrated by this #target.
    #
    # @return [Array<PBXNativeTarget>]
    #
    def user_targets
      return [] unless user_project
      user_target_uuids.map do |uuid|
        native_target = user_project.objects_by_uuid[uuid]
        unless native_target
          raise Informative, '[Bug] Unable to find the target with ' \
            "the `#{uuid}` UUID for the `#{self}` integration library"
        end
        native_target
      end
    end

    # @param  [String] build_configuration The build configuration for which the
    #         the pod targets should be returned.
    #
    # @return [Array<PodTarget>] the pod targets for the given build
    #         configuration.
    #
    def pod_targets_for_build_configuration(build_configuration)
      @pod_targets_for_build_configuration[build_configuration] || []
    end

    # @return [Array<Specification>] The specifications used by this aggregate target.
    #
    def specs
      pod_targets.flat_map(&:specs)
    end

    # @return [Hash{Symbol => Array<Specification>}] The pod targets for each
    #         build configuration.
    #
    def specs_by_build_configuration
      result = {}
      user_build_configurations.each_key do |build_configuration|
        result[build_configuration] = pod_targets_for_build_configuration(build_configuration).
          flat_map(&:specs)
      end
      result
    end

    # @return [Array<Specification::Consumer>] The consumers of the Pod.
    #
    def spec_consumers
      specs.map { |spec| spec.consumer(platform) }
    end

    # @return [Boolean] Whether the target uses Swift code
    #
    def uses_swift?
      pod_targets.any?(&:uses_swift?)
    end

    # @return [Boolean] Whether the target contains any resources
    #
    def includes_resources?
      !resource_paths_by_config.each_value.all?(&:empty?)
    end

    # @return [Boolean] Whether the target contains any on demand resources
    #
    def includes_on_demand_resources?
      !on_demand_resources.empty?
    end

    # @return [Boolean] Whether the target contains frameworks to be embedded into
    #         the user target
    #
    def includes_frameworks?
      !framework_paths_by_config.each_value.all?(&:empty?)
    end

    # @return [Boolean] Whether the target contains xcframeworks to be embedded into
    #         the user target
    #
    def includes_xcframeworks?
      !xcframeworks_by_config.each_value.all?(&:empty?)
    end

    # @return [Hash{String => Array<FrameworkPaths>}] The vendored dynamic artifacts and framework target
    #         input and output paths grouped by config
    #
    def framework_paths_by_config
      @framework_paths_by_config ||= begin
        framework_paths_by_config = {}
        user_build_configurations.each_key do |config|
          relevant_pod_targets = pod_targets_for_build_configuration(config)
          framework_paths_by_config[config] = relevant_pod_targets.flat_map do |pod_target|
            library_specs = pod_target.library_specs.map(&:name)
            pod_target.framework_paths.values_at(*library_specs).flatten.compact.uniq
          end
        end
        framework_paths_by_config
      end
    end

    # @return [Hash{String => Array<Xcode::XCFramework>}] The vendored dynamic artifacts and framework target
    #         input and output paths grouped by config
    #
    def xcframeworks_by_config
      @xcframeworks_by_config ||= begin
        xcframeworks_by_config = {}
        user_build_configurations.each_key do |config|
          relevant_pod_targets = pod_targets_for_build_configuration(config)
          xcframeworks_by_config[config] = relevant_pod_targets.flat_map do |pod_target|
            library_specs = pod_target.library_specs.map(&:name)
            pod_target.xcframeworks.values_at(*library_specs).flatten.compact.uniq
          end
        end
        xcframeworks_by_config
      end
    end

    # @return [Array<Pathname>] Uniqued On Demand Resources for this target.
    #
    # @note On Demand Resources are not separated by config as they are integrated directly into the users target via
    # the resources build phase.
    #
    def on_demand_resources
      @on_demand_resources ||= begin
        pod_targets.flat_map do |pod_target|
          library_file_accessors = pod_target.file_accessors.select { |fa| fa.spec.library_specification? }
          library_file_accessors.flat_map { |fa| fa.on_demand_resources.values.flatten }
        end.uniq
      end
    end

    # @return [Hash{String => Array<String>}] Uniqued Resources grouped by config
    #
    def resource_paths_by_config
      @resource_paths_by_config ||= begin
        relevant_pod_targets = pod_targets.reject do |pod_target|
          pod_target.should_build? && pod_target.build_as_dynamic_framework?
        end
        user_build_configurations.each_key.each_with_object({}) do |config, resources_by_config|
          targets = relevant_pod_targets & pod_targets_for_build_configuration(config)
          resources_by_config[config] = targets.flat_map do |pod_target|
            library_specs = pod_target.library_specs.map(&:name)
            resource_paths = pod_target.resource_paths.values_at(*library_specs).flatten

            if pod_target.build_as_static_framework?
              built_product_dir = Pathname.new(pod_target.build_product_path('${BUILT_PRODUCTS_DIR}'))
              resource_paths = resource_paths.map do |resource_path|
                extname = File.extname(resource_path)
                if self.class.resource_extension_compilable?(extname)
                  output_extname = self.class.output_extension_for_resource(extname)
                  built_product_dir.join(File.basename(resource_path)).sub_ext(output_extname).to_s
                else
                  resource_path
                end
              end
            end

            resource_paths << bridge_support_file
            resource_paths.compact.uniq
          end
        end
      end
    end

    # @return [Pathname] the path of the bridge support file relative to the
    #         sandbox or `nil` if bridge support is disabled.
    #
    def bridge_support_file
      bridge_support_path.relative_path_from(sandbox.root) if podfile.generate_bridge_support?
    end

    #-------------------------------------------------------------------------#

    # @!group Support files

    # @return [Pathname] The absolute path of acknowledgements file.
    #
    # @note   The acknowledgements generators add the extension according to
    #         the file type.
    #
    def acknowledgements_basepath
      support_files_dir + "#{label}-acknowledgements"
    end

    # @return [Pathname] The absolute path of the copy resources script.
    #
    def copy_resources_script_path
      support_files_dir + "#{label}-resources.sh"
    end

    # @return [Pathname] The absolute path of the embed frameworks script.
    #
    def embed_frameworks_script_path
      support_files_dir + "#{label}-frameworks.sh"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the copy resources script input file list.
    #
    def copy_resources_script_input_files_path(configuration)
      support_files_dir + "#{label}-resources-#{configuration}-input-files.xcfilelist"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the copy resources script output file list.
    #
    def copy_resources_script_output_files_path(configuration)
      support_files_dir + "#{label}-resources-#{configuration}-output-files.xcfilelist"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the embed frameworks script input file list.
    #
    def embed_frameworks_script_input_files_path(configuration)
      support_files_dir + "#{label}-frameworks-#{configuration}-input-files.xcfilelist"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the embed frameworks script output file list.
    #
    def embed_frameworks_script_output_files_path(configuration)
      support_files_dir + "#{label}-frameworks-#{configuration}-output-files.xcfilelist"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the prepare artifacts script input file list.
    #
    # @deprecated
    #
    # @todo Remove in 2.0
    #
    def prepare_artifacts_script_input_files_path(configuration)
      support_files_dir + "#{label}-artifacts-#{configuration}-input-files.xcfilelist"
    end

    # @param  [String] configuration the configuration this path is for.
    #
    # @return [Pathname] The absolute path of the prepare artifacts script output file list.
    #
    # @deprecated
    #
    # @todo Remove in 2.0
    #
    def prepare_artifacts_script_output_files_path(configuration)
      support_files_dir + "#{label}-artifacts-#{configuration}-output-files.xcfilelist"
    end

    # @return [String] The output file path fo the check manifest lock script.
    #
    def check_manifest_lock_script_output_file_path
      "$(DERIVED_FILE_DIR)/#{label}-checkManifestLockResult.txt"
    end

    # @return [Pathname] The relative path of the Pods directory from user project's directory.
    #
    def relative_pods_root_path
      sandbox.root.relative_path_from(client_root)
    end

    # @return [String] The xcconfig path of the root from the `$(SRCROOT)`
    #         variable of the user's project.
    #
    def relative_pods_root
      "${SRCROOT}/#{relative_pods_root_path}"
    end

    # @return [String] The path of the Podfile directory relative to the
    #         root of the user project.
    #
    def podfile_dir_relative_path
      podfile_path = target_definition.podfile.defined_in_file
      return "${SRCROOT}/#{podfile_path.relative_path_from(client_root).dirname}" unless podfile_path.nil?
      # Fallback to the standard path if the Podfile is not represented by a file.
      '${PODS_ROOT}/..'
    end

    # @param  [String] config_name The build configuration name to get the xcconfig for
    # @return [String] The path of the xcconfig file relative to the root of
    #         the user project.
    #
    def xcconfig_relative_path(config_name)
      xcconfig_path(config_name).relative_path_from(client_root).to_s
    end

    # @return [String] The path of the copy resources script relative to the
    #         root of the Pods project.
    #
    def copy_resources_script_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(copy_resources_script_path)}"
    end

    # @return [String] The path of the copy resources script input file list
    #         relative to the root of the Pods project.
    #
    def copy_resources_script_input_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(copy_resources_script_input_files_path('${CONFIGURATION}'))}"
    end

    # @return [String] The path of the copy resources script output file list
    #         relative to the root of the Pods project.
    #
    def copy_resources_script_output_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(copy_resources_script_output_files_path('${CONFIGURATION}'))}"
    end

    # @return [String] The path of the embed frameworks relative to the
    #         root of the Pods project.
    #
    def embed_frameworks_script_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(embed_frameworks_script_path)}"
    end

    # @return [String] The path of the embed frameworks script input file list
    #         relative to the root of the Pods project.
    #
    def embed_frameworks_script_input_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(embed_frameworks_script_input_files_path('${CONFIGURATION}'))}"
    end

    # @return [String] The path of the embed frameworks script output file list
    #         relative to the root of the Pods project.
    #
    def embed_frameworks_script_output_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(embed_frameworks_script_output_files_path('${CONFIGURATION}'))}"
    end

    # @return [String] The path of the prepare artifacts script relative to the
    #         root of the Pods project.
    #
    # @deprecated
    #
    # @todo Remove in 2.0
    #
    def prepare_artifacts_script_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(prepare_artifacts_script_path)}"
    end

    # @return [String] The path of the prepare artifacts script input file list
    #         relative to the root of the Pods project.
    #
    # @deprecated
    #
    # @todo Remove in 2.0
    #
    def prepare_artifacts_script_input_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(prepare_artifacts_script_input_files_path('${CONFIGURATION}'))}"
    end

    # @return [String] The path of the prepare artifacts script output file list
    #         relative to the root of the Pods project.
    #
    # @deprecated
    #
    # @todo Remove in 2.0
    #
    def prepare_artifacts_script_output_files_relative_path
      "${PODS_ROOT}/#{relative_to_pods_root(prepare_artifacts_script_output_files_path('${CONFIGURATION}'))}"
    end

    private

    # @!group Private Helpers
    #-------------------------------------------------------------------------#

    # Computes the relative path of a sandboxed file from the `$(PODS_ROOT)`
    # variable of the Pods's project.
    #
    # @param  [Pathname] path
    #         A relative path from the root of the sandbox.
    #
    # @return [String] The computed path.
    #
    def relative_to_pods_root(path)
      path.relative_path_from(sandbox.root).to_s
    end

    def create_build_settings
      settings = {}

      user_build_configurations.each do |configuration_name, configuration|
        settings[configuration_name] = BuildSettings::AggregateTargetSettings.new(self, configuration_name, :configuration => configuration)
      end

      settings
    end
  end
end
