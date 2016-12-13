class Config

  def self.conf
    if File.exist?(File.dirname(__FILE__) + '/../config/conf.yml')
      conf = YAML.load_file(File.dirname(__FILE__) + '/../config/conf.yml')
    else
      conf = {}
    end
    config = {}
    config['testing'] = conf['testing'] || 0
    conf['reload_times'] = {} unless conf['reload_times']
    config['fees'] = conf['reload_times']['fees'] || 3600
    config['pairs'] = conf['reload_times']['pairs'] || 3600
    config['configuration'] = conf['reload_times']['configuration'] || 180
    config['ring_balances'] = conf['reload_times']['ring_balances'] || 180
    conf['arbitrage'] = {} unless conf['arbitrage']
    config['arbitrage_buffer'] = conf['arbitrage']['buffer'] || 0.005
    config['arbitrage_max_amount'] = conf['arbitrage']['max_amount'] || 1000
    config['arbitrage_on_margin'] = conf['arbitrage']['on_margin'] || 0
    config
  end

end