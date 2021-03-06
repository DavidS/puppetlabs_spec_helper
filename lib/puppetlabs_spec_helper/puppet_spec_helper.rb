# frozen_string_literal: true

require 'puppetlabs_spec_helper/puppetlabs_spec_helper'

# Don't want puppet getting the command line arguments for rake or autotest
ARGV.clear

require 'puppet'
require 'rspec/expectations'

# Detect whether the module is overriding the choice of mocking framework
# @mock_framework is used since more than seven years, and we need to avoid
# `mock_framework`'s autoloading to distinguish between the default, and
# the module's choice.
# See also below in RSpec.configure
if RSpec.configuration.instance_variable_get(:@mock_framework).nil?
  # This is needed because we're using mocha with rspec instead of Test::Unit or MiniTest
  ENV['MOCHA_OPTIONS'] = 'skip_integration'

  # Current versions of RSpec already load this for us, but who knows what's used out there?
  require 'mocha/api'
end

require 'pathname'
require 'tmpdir'

require 'puppetlabs_spec_helper/puppetlabs_spec/files'

######################################################################################
#                                     WARNING                                        #
######################################################################################
#
# You should probably be frightened by this file.  :)
#
# The goal of this file is to try to maximize spec-testing compatibility between
# multiple versions of various external projects (which depend on puppet core) and
# multiple versions of puppet core itself.  This is accomplished via a series
# of hacks and magical incantations that I am not particularly proud of.  However,
# after discussion it was decided that the goal of achieving compatibility was
# a very worthy one, and that isolating the hacks to one place in a non-production
# project was as good a solution as we could hope for.
#
# You may want to hold your nose before you proceed. :)
#

# Here we attempt to load the new TestHelper API, and print a warning if we are falling back
# to compatibility mode for older versions of puppet.
begin
  require 'puppet/test/test_helper'
rescue LoadError => e
end

# This is just a utility class to allow us to isolate the various version-specific
# branches of initialization logic into methods without polluting the global namespace.#
module Puppet
  class PuppetSpecInitializer
    # This method is for initializing puppet state for testing for older versions
    # of puppet that do not support the new TestHelper API.  As you can see,
    # this involves explicitly modifying global variables, directly manipulating
    # Puppet's Settings singleton object, and other fun implementation details
    # that code external to puppet should really never know about.
    def self.initialize_via_fallback_compatibility(config)
      warn('Warning: you appear to be using an older version of puppet; spec_helper will use fallback compatibility mode.')
      config.before :all do
        # nothing to do for now
      end

      config.after :all do
        # nothing to do for now
      end

      config.before :each do
        # these globals are set by Application
        $puppet_application_mode = nil
        $puppet_application_name = nil

        # REVISIT: I think this conceals other bad tests, but I don't have time to
        # fully diagnose those right now.  When you read this, please come tell me
        # I suck for letting this float. --daniel 2011-04-21
        Signal.stubs(:trap)

        # Set the confdir and vardir to gibberish so that tests
        # have to be correctly mocked.
        Puppet[:confdir] = '/dev/null'
        Puppet[:vardir] = '/dev/null'

        # Avoid opening ports to the outside world
        Puppet.settings[:bindaddress] = '127.0.0.1'
      end

      config.after :each do
        Puppet.settings.clear

        Puppet::Node::Environment.clear
        Puppet::Util::Storage.clear
        Puppet::Util::ExecutionStub.reset if Puppet::Util.constants.include? 'ExecutionStub'

        PuppetlabsSpec::Files.cleanup
      end
    end
  end
end

# JJM Hack to make the stdlib tests run in Puppet 2.6 (See puppet commit cf183534)
unless Puppet.constants.include? 'Test'
  module Puppet::Test
    class LogCollector
      def initialize(logs)
        @logs = logs
      end

      def <<(value)
        @logs << value
      end
    end
  end
  Puppet::Util::Log.newdesttype :log_collector do
    match 'Puppet::Test::LogCollector'

    def initialize(messages)
      @messages = messages
    end

    def handle(msg)
      @messages << msg
    end
  end
end

# And here is where we do the main rspec configuration / setup.
RSpec.configure do |config|
  # Detect whether the module is overriding the choice of mocking framework
  # @mock_framework is used since more than seven years, and we need to avoid
  # `mock_framework`'s autoloading to distinguish between the default, and
  # the module's choice.
  if config.instance_variable_get(:@mock_framework).nil?
    RSpec.warn_deprecation('puppetlabs_spec_helper: defaults `mock_with` to `:mocha`. See https://github.com/puppetlabs/puppetlabs_spec_helper#mock_with to choose a sensible value for you')
    config.mock_with :mocha
  end

  # determine whether we can use the new API or not, and call the appropriate initializer method.
  if defined?(Puppet::Test::TestHelper)
    # This case is handled by rspec-puppet since v1.0.0 (via 41257b33cb1f9ade4426b044f70be511b0c89112)
  else
    Puppet::PuppetSpecInitializer.initialize_via_fallback_compatibility(config)
  end

  # Here we do some general setup that is relevant to all initialization modes, regardless
  # of the availability of the TestHelper API.

  config.before :each do
    # Here we redirect logging away from console, because otherwise the test output will be
    #  obscured by all of the log output.
    #
    # TODO: in a more sane world, we'd move this logging redirection into our TestHelper
    #  class, so that it was not coupled with a specific testing framework (rspec in this
    #  case).  Further, it would be nicer and more portable to encapsulate the log messages
    #  into an object somewhere, rather than slapping them on an instance variable of the
    #  actual test class--which is what we are effectively doing here.
    #
    # However, because there are over 1300 tests that are written to expect
    #  this instance variable to be available--we can't easily solve this problem right now.
    @logs = []
    Puppet::Util::Log.newdestination(Puppet::Test::LogCollector.new(@logs))

    @log_level = Puppet::Util::Log.level
  end

  config.after :each do
    # clean up after the logging changes that we made before each test.

    # TODO: this should be abstracted in the future--see comments above the '@logs' block in the
    #  "before" code above.
    @logs.clear
    Puppet::Util::Log.close_all
    Puppet::Util::Log.level = @log_level
  end
end
