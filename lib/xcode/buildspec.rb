require 'rake'
require 'rake/tasklib'
require 'versionomy'

module Xcode

  class Buildspec

    #
    # Given a path to a Buildspec, define rake tasks
    #
    # @param the path to the Buildspec file, or a directory containing one
    #
    def self.parse(path = '.')
      b = GroupBuilder.new
      path = File.join(path, 'Buildspec') if File.directory? path
      b.instance_eval(File.read(path))
      b.generate_rake_tasks
    end

    #
    # Given a path to a buildspec, perform the given task
    #
    # @param the path to the buildspec, or the directory containing one
    # @param the task to invoke
    #
    def self.run(path, task)
      self.parse path
      Rake::Task[task].invoke unless task.nil?
    end

    class GroupBuilder < ::Rake::TaskLib
      include ::Rake::DSL if defined?(::Rake::DSL)

      def initialize 
        @groups = []
      end

      def group group, &block
        @groups << group.downcase
        namespace group.downcase do 
          t = TaskBuilder.new
          t.instance_eval(&block)
          t.generate_rake_tasks
        end
      end

      def generate_rake_tasks

        # namespace :all do 
          # define top level tasks
          desc "Build all"
          task :build => @groups.map {|g| "#{g}:build"}

          desc "Clean all"
          task :clean => @groups.map {|g| "#{g}:clean"}

          desc "Package all"
          task :package => @groups.map {|g| "#{g}:package"}

          desc "Deploy all"
          task :deploy => @groups.map {|g| "#{g}:deploy:all"}
        # end
      end
    end

    class TaskBuilder < ::Rake::TaskLib

      include ::Rake::DSL if defined?(::Rake::DSL)

      def initialize
        @before = lambda {|builder| return nil }
        @deployments = []
        # @profile = "Provisioning/#{name}.mobileprovision"
      end

      #
      # Use the given project/workspace file
      #
      # This must be provided.
      #
      # @param the path to the .xcodeproj or .xcworkspace
      # @param a hash containing {:scheme => ''} or {:target => '', :config => ''}
      #
      def use filename, args={}
        @filename = filename
        @args = args
      end

      #
      # A block to run before each builder invocation
      #
      # If supplied, the block will be yielded the builder object just before the invocation
      # of clean/build/package
      #
      # @param the block to call
      #
      def before &block
        @before = block
      end

      # 
      # Generate the build number
      #
      # @param a hash containing {:version => false, marketing_version => false}
      #
      def build_number args={}
        @build_number = lambda do
          builder.config.info_plist do |info|
          info.version = info.version.to_i + 1 if args[:version]
          if args[:marketing_version]
            marketing_version = Versionomy.parse(info.marketing_version)
            info.marketing_version = marketing_version.bump(:tiny).to_s
          end
          info.save
          end
        end
      end

      #
      # Configure a keychain to use (optional)
      #
      # If specified, the keychain at the given path will be unlocked during the build and
      # the first identity will be set on the builder
      #
      # @param the path to the keychain
      # @param the password to unlock the keychain
      #
      def keychain path, password = nil
        @keychain = {:path => path, :password => password}
      end
      
      
      #
      # Specify the platform to build for
      #
      # @param the platform, can be 'iphone', 'iphonesimulator', 'macosx'
      # @param the version, can be any valid, installed sdk version for the appropriate platform or nil
      def platform name, version=nil
        @platform = Xcode::Platforms.find name, version
      end
      
      # 
      # Set's the identity to use to sign the package
      #
      # This should be the name of the identity in your keychain, such as 
      # 'iPhone Distribution: My Name'
      #
      # @param the name of the identity
      #
      def identity identity
        @identity = identity
      end

      #
      # Set the profile (i.e. .mobileprovision) to use
      #
      # @param the name or path to the profile
      def profile profile
        @profile = profile
      end

      #
      # Set a deployment target.
      #
      # This will configure a set of deploy: targets that
      # will send the .ipa to various services (testflight, s3, ftp, sftp, etc)
      #
      # @param the deployment type (testflight, etc)
      # @param arguments to pass to the deployment type
      #
      def deploy type, args = {}
        @deployments << {:type => type, :args => args}
      end


      def notify type, args = {}
        @notifications << {:type => type, :args => args}
      end


      #
      # Internally used to lazily instantiate the builder given the properties that
      # have been set.
      #
      # @return the appropriate builder
      #
      def builder
        return @builder unless @builder.nil?

        raise "profile must be defined" if @profile.nil?
        raise "project/workspace must be defined" if @filename.nil?

        begin 
          project = Xcode.project @filename
          @builder = project.target(@args[:target]).config(@args[:config]).builder
        rescue
          workspace = Xcode.workspace @filename
          @builder = workspace.scheme(@args[:scheme]).builder
        rescue
          raise "You must provide a project or workspace"          
        end

        raise "Could not create a builder using #{@args}" if @builder.nil?
        
        unless @platform.nil?
          builder.sdk = @platform.sdk
        end

        unless @identity.nil?
          builder.identity = @identity
        end

        unless @keychain.nil?
          keychain = Xcode::Keychain.new @keychain[:path]
          keychain.unlock @keychain[:password] unless @keychain[:password].nil?

          builder.identity = keychain.identities.first
          builder.keychain = keychain
        end

        builder.profile = @profile

        @before.call builder

        @builder
      end

      def project_name
        builder.product_name
      end

      #
      # Create a set of rake tasks for this buildspec
      #
      def generate_rake_tasks
        require 'socket'

        # namespace project_name.downcase do

        desc "Clean #{project_name}"
        task :clean do
          builder.clean
        end

        desc "Fetch dependencies for #{project_name}"
        task :deps do
          builder.dependencies
        end

        desc "Build #{project_name}"
        task :build => [:clean, :deps] do
          @build_number.call
          builder.build
        end

        desc "Test #{project_name}"
        task :test => [:deps] do
          builder.test
        end

        desc "Package (.ipa & .dSYM.zip) #{project_name}"
        task :package => [:build, :test] do
          builder.package
        end

        namespace :deploy do
          @deployments.each do |deployment|
            desc "Deploy #{project_name} to #{deployment[:type]}"
            task deployment[:type]  => [:package] do
              builder.deploy deployment[:type], deployment[:args]
            end
          end

          desc "Deploy #{project_name} to all"
          task :all  => [:package]+(@deployments.map{|k,v| k[:type]}) do
            puts "Deployed to all"
          end
        end
      end
      # end
    end

  end
end