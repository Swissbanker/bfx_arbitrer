#!/usr/local/bin/ruby

# Example application to demonstrate some basic Ruby features
# This code loads a given file into an associated application

require 'yaml'
#Require bundle and gems management
require 'rubygems'
require 'bundler/setup'
require 'bitfinex'
require 'bigdecimal/math'
require 'bigdecimal/util'
require 'hamster/sorted_set'
#Process.daemon

class BfxArbitrer

  def initialize
    #Require app file
    Dir[File.dirname(__FILE__) + '/app/*.rb'].each {|file| require file }
    configs = YAML.load_file(File.dirname(__FILE__) + '/config/secrets.yml')
    Bitfinex::Client.configure do |conf|
      conf.secret = configs['BFX_API_SECRET']
      conf.api_key = configs['BFX_API_KEY']
    end
    $client = Bitfinex::Client.new
    $logger = Logger.new(File.dirname(__FILE__) + '/log/grey_wizard.log')
    $logger_error = Logger.new(File.dirname(__FILE__) + '/log/grey_wizard_errors.log')
  end

  def self.run
    $logger.info("Hello")
    wizard = Arbitrer.new
  end
end

BfxArbitrer.new
BfxArbitrer.run