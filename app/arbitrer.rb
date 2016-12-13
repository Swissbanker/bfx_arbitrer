class Arbitrer

  def initialize()
    @reload = {:startup => Time.now}
    @conf = nil
    @tickers = {}
    @orderbook = {}
    @balances = {}
    @available_ring_balance = {}
    @orders = []
    @positions = []
    reload
    $client.listen_account do |event|
      do_triage_account_info(event)
    end
    @pairs_list.each do |pair|
      $client.listen_ticker(pair) do |tick|
        @tickers[pair] = ParseUtils.parse_ws_ticker(tick)
        @overall_balance = get_overall_balance
        reload
      end
      $client.listen_book(pair, "P0", "F0", 25) do |book|
        @orderbook[pair] = {} unless @orderbook[pair]
        @orderbook[pair], level = ParseUtils.parse_ws_book(@orderbook[pair], book)
        get_arbitrage_opportunity(level, pair) unless level.empty?
      end
    end
    @overall_balance = 0
    $client.listen!
  end

  def do_place_orders(orders)
    params = []
    orders.each do |order|
      if order[:amount] > 0
        side = 'buy'
      else
        side = 'sell'
      end
      type = (@conf['arbitrage_on_margin'] && @conf['arbitrage_on_margin'].to_d != 1) ? "exchange #{order[:type]}" : "#{order[:type]}"
      params << {
          symbol: order[:pair],
          amount: order[:amount].abs.to_f.to_s,
          type: type,
          side: side,
          exchange: 'bitfinex',
          price: order[:price].to_f.to_s
      }
      if order[:amount].abs < get_pair(order[:pair])['minimum_order_size'].to_d || order[:amount].abs > get_pair(order[:pair])['maximum_order_size'].to_d
        LogService.log_thing("DO_PLACE_ORDERS: Invalid order size #{order[:amount].abs} for pair #{order[:pair]}, exiting")
        return
      end
    end
    if @prod
      orders = $client.multiple_orders(params)
      do_update_orders(orders['order_ids'], 'on')
    end
    LogService.log_thing("DO_PLACE_ORDERS: Placing the following orders: #{params}")
  rescue Exception => e
    LogService.error_log(e, "Arbitrer.do_place_orders(#{orders})")
  end

  def do_triage_account_info(event)
    case event[1]
      when 'ws', 'wu'
        updated_currency = do_update_balances(event[2])
        reload_max_ring_balance(updated_currency)
      when 'os', 'on', 'ou', 'oc'
        do_update_orders(event[2], event[1])
      when 'ps', 'pn', 'pu', 'pc'
        do_update_positions(event[2], event[1])
    end
  end

  def do_update_balance(balance)
    @balances[balance[0]] = {} unless @balances[balance[0]]
    @balances[balance[0]][balance[1].to_s.downcase] = {} unless @balances[balance[0]][balance[1].to_s.downcase]
    @balances[balance[0]][balance[1].to_s.downcase] = {'amount' => balance[2], 'unsettled_interest' => balance[3]}
    balance[1].to_s.downcase
  end

  def do_update_balances(data)
    updated_currency = nil
    if data[0].is_a?(Array)
      data.each do |balance|
        do_update_balance(balance)
      end
    else
      updated_currency = do_update_balance(data)
    end
    LogService.log_thing "@balances #{@balances}"
    updated_currency
  end

  def do_update_order(order, action)
    if order.is_a?(Hash)
      @orders.delete_if { |x| x['id'] == order['id'].to_i }
      @orders << {
          'id' => order['id'].to_i,
          'pair' => order['symbol'],
          'amount' => order['remaining_amount'].to_d,
          'original_amount' => order['original_amount'].to_d,
          'type' => order['type'],
          'status' => 'ACTIVE',
          'price' => (order['price'] || 0).to_d,
          'avg_price' => order['avg_execution_price'].to_d,
          'created_at' => Time.at(order['timestamp'].to_s),
          'notify' => 0,
          'hidden' => 0,
          'oco' => 0
      } if ['os', 'on', 'ou'].include?(action)
    else
      @orders.delete_if { |x| x['id'] == order[0].to_i }
      @orders << {
          'id' => order[0].to_i,
          'pair' => order[1],
          'amount' => order[2].to_d,
          'original_amount' => order[3].to_d,
          'type' => order[4],
          'status' => order[5],
          'price' => (order[6] || 0).to_d,
          'avg_price' => order[7].to_d,
          'created_at' => Time.parse(order[8].to_s),
          'notify' => order[9],
          'hidden' => order[10],
          'oco' => order[11]
      } if ['os', 'on', 'ou'].include?(action) && order[1]
    end
  end

  def do_update_orders(data, action)
    if data[0] && (data[0].is_a?(Array) || data[0].is_a?(Hash))
      data.each do |o|
        do_update_order(o, action)
      end
    else
      do_update_order(data, action)
    end
    LogService.log_thing "@orders #{@orders}"
  end

  def do_update_position(position, action)
    @positions.delete_if { |x| x['id'] == position[0].to_i }
    @positions << {
        'pair' => position[0].to_i,
        'status' => position[1],
        'amount' => position[2].to_d,
        'base' => position[3].to_d,
        'swap' => position[4].to_d,
        'swap_type' => position[5].to_d
    } if ['ps', 'pn', 'pu'].include?(action) && position[1]
  end

  def do_update_positions(data, action)
    if data[0] && data[0].is_a?(Array)
      data.each do |p|
        do_update_position(p, action)
      end
    else
      do_update_position(data, action)
    end
    LogService.log_thing "@positions #{@positions}"
  end

  def get_arbitrage_opportunity(level, pair)
    best_bid, best_ask = get_best_bidask(pair)
    return 0, "" if (level['price'] != best_bid && level['price'] != best_ask) || level['amount'] == 0
    #LogService.log_thing("GET_ARBITRAGE_OPPORTUNITY: Trying up order #{level['amount'].to_f} #{pair} at #{level['price'].to_f}")
    if @conf['arbitrage_max_amount']
      max_val = get_currency_value(@conf['arbitrage_max_amount'].to_d, 'usd', pair[0..2])
      level['amount'] = [level['amount'].abs, max_val].min * level['amount'] / level['amount'].abs
      #LogService.log_thing("GET_ARBITRAGE_OPPORTUNITY: Adjusted amount is #{level['amount'].to_f}")
    end
    @ring_pairs.each do |ring|
      next unless ring.include?(pair)
      c_max = [get_currency_value(@available_ring_balance[ring.to_s.to_sym] * 0.99, 'usd', pair[0..2]), level['amount'].abs].min
      next unless c_max > 0
      amount = {}
      orders = []
      amount[pair[0..2]] = -c_max * level['amount'] / level['amount'].abs
      initial_ccy = nil
      c_amount, c_ccy = c_max * level['amount'] / level['amount'].abs, pair[0..2]
      cpt = 0
      while true do
        c_pair = ring[cpt]
        cpt = (cpt + 1) % 3
        break if initial_ccy && initial_ccy == c_ccy
        next unless (initial_ccy && c_pair.include?(c_ccy)) || (initial_ccy.nil? && c_pair == pair)
        initial_ccy = c_ccy unless initial_ccy
        amount[c_pair[0..2]] = 0 unless amount[c_pair[0..2]]
        amount[c_pair[3..5]] = 0 unless amount[c_pair[3..5]]
        f_amount, c_amount, c_ccy, _, limit_price = get_depth_value(c_amount, c_ccy, c_pair)
        break if c_ccy == ''
        amount[c_ccy] += c_amount
        c_amount = amount[c_ccy]
        orders << {:amount => f_amount, :price => limit_price, :pair => c_pair, :type => 'limit'}
      end
      if c_amount > 0
        LogService.log_thing("GET_ARBITRAGE_OPPORTUNITY: Arbitrage opportunity on ring #{ring}, let's go. Should yield #{c_amount.to_f} #{c_ccy}")
        do_place_orders(orders)
      end
    end
  end

  def get_best_bidask(pair)
    return (@orderbook[pair]['bid'].first ? @orderbook[pair]['bid'].first['price'] : nil), (@orderbook[pair]['ask'].first ? @orderbook[pair]['ask'].first['price'] : nil)
  end

  def get_currency_value(amount, ccy_from, ccy_to = "usd", mid = false)
    pair = ccy_from.downcase + ccy_to.downcase
    pair = pair[3..5] + pair[0..2] unless @pairs_list.include?(pair)
    get_currency_value = amount
    if ccy_from != ccy_to && @pairs_list.include?(pair) && @tickers[pair]
      if mid
        get_currency_value = amount / ((@tickers[pair]['bid'] + @tickers[pair]['ask']) / 2) if pair.start_with?(ccy_to)
        get_currency_value = amount * ((@tickers[pair]['bid'] + @tickers[pair]['ask']) / 2) if pair.start_with?(ccy_from)
      else
        get_currency_value = amount / @tickers[pair]['ask'] if pair.start_with?(ccy_to)
        get_currency_value = amount * @tickers[pair]['bid'] if pair.start_with?(ccy_from)
      end
    end
    get_currency_value
  end

  def get_depth_value(amount, currency, pair)
    return 0, 0, "", 0, 0 unless pair[0..2] == currency || pair[3..5] == currency
    #LogService.log_thing("GET_DEPTH_VALUE: Starting with amount #{amount.to_f}, currency #{currency} and pair #{pair}")
    result_value, first_unit_amount = 0, 0
    avg_price, max_price = 0, 0
    result_currency = pair[0..2] == currency ? pair[3..5] : pair[0..2]
    remaining = amount.abs
    book = ((amount > 0 && pair[3..5] == currency) || (amount < 0 && pair[0..2] == currency)) ?
        @orderbook[pair]['ask'] :
        @orderbook[pair]['bid']
    multiplier = pair[0..2] == currency ? 1 : -1
    book.each do |lev|
      break if remaining <= 0
      max_price = lev['price']
      l_amount = (pair[0..2] == currency) ? lev['amount'] : lev['amount'] * lev['price']
      l_amount = remaining >= l_amount.abs ? l_amount : remaining * l_amount / l_amount.abs
      avg_price = (avg_price * (amount.abs - remaining) + l_amount * lev['price']) / (amount.abs - remaining + l_amount)
      remaining -= l_amount.abs
      if pair[0..2] == currency
        result_value += l_amount * lev['price'] * multiplier
      else
        result_value += l_amount / lev['price'] * multiplier
      end
      result_value -= (@fees['taker_fees'].to_d + @conf['arbitrage_buffer']) * result_value.abs
      first_unit_amount -= (pair[0..2] == currency) ? l_amount : l_amount / lev['price']
    end
    #LogService.log_thing("GET_DEPTH_VALUE: first_unit_amount #{first_unit_amount.to_f}, result_value #{result_value.to_f}, result_currency #{result_currency}, avg_price #{avg_price.to_f}, max_price #{max_price.to_f}")
    return first_unit_amount, result_value, result_currency, avg_price, max_price
  rescue => e
    LogService.error_log(e, "Arbitrer.get_depth_value")
    return 0, 0, "", 0, 0
  end

  def get_max_ring_tradable_balance(type, ring)
    ccys_done = []
    max = nil
    ring.each do |pair|
      [pair[0..2], pair[3..5]].each do |ccy|
        unless ccys_done.include?(ccy)
          _, available = get_wallet_balance(type, ccy, true)
          max = max.nil? ? get_currency_value(available, ccy) : [get_currency_value(available, ccy), max].min
          ccys_done << ccy
        end
      end
    end
    max
  end

  def get_pair(pair)
    @pairs.select { |x| x['pair'] == pair }.first
  end

  def get_positions(pair = "")
    pair != "" ? @positions.select { |o| o['pair'] == pair } : @positions
  end

  def get_orders(pair = "")
    pair != "" ? @orders.select { |o| o['pair'] == pair } : @orders
  end

  def get_overall_balance
    get_overall_balance = 0
    @balances.each do |_, walletbal|
      walletbal.each do |ccy, bal|
        get_overall_balance += get_currency_value(bal['amount'].to_d, ccy)
      end
    end
    LogService.log_thing "Overall balance is now #{get_overall_balance.to_f} USD" unless get_overall_balance == @overall_balance
    get_overall_balance
  end

  def get_ring(level)
    @ring_pairs = []
    @pairs_list.each do |pair|
      current = [pair]
      (2..level).each do |l|
        @pairs_list.each do |pair2|
          next if current.include?(pair2)
          next unless (current[1].nil? && (current[0].include?(pair2[0..2]) || current[0].include?(pair2[3..5]))) ||
              (current[0].include?(pair2[0..2]) && current[1].include?(pair2[3..5])) || (current[0].include?(pair2[3..5]) && current[1].include?(pair2[0..2]))
          current << pair2
        end
      end
      @ring_pairs << current unless @ring_pairs.map { |r| r.sort }.include?(current.sort) || current.size < level
    end
  end

  def get_standing_orders(currency, order_type = "trading")
    standing_orders = 0
    if order_type == "exchange"
      @orders.select { |o| ['EXCHANGE LIMIT', 'EXCHANGE STOP', 'EXCHANGE TRAILING STOP', 'EXCHANGE MARKET'].include?(o['type']) && o['amount'] < 0 && o['pair'].start_with?(currency) }.each do |order|
        standing_orders += order['amount'].abs
      end
      @orders.select { |o| ['EXCHANGE LIMIT', 'EXCHANGE STOP', 'EXCHANGE TRAILING STOP', 'EXCHANGE MARKET'].include?(o['type']) && o['amount'] > 0 && o['pair'].end_with?(currency) }.each do |order|
        standing_orders += order.amount.to_d.abs * order.price.to_d if order.type != 'EXCHANGE MARKET'
        standing_orders += order['amount'].abs * @tickers[order['pair']]['ask'].to_d if order['type'] == 'EXCHANGE MARKET'
      end
    end
    standing_orders = 0 if standing_orders < 0
    standing_orders
  end

  def get_wallet_balance(wallet_type, currency, check_availability = false)
    total, available = 0, 0
    return 1000, 1000 unless @prod
    da_wallet = @balances[wallet_type]
    total += da_wallet[currency]['amount'].to_d if da_wallet && da_wallet[currency]
    if check_availability
      case wallet_type
        when 'exchange'
          available += total - get_standing_orders(currency, wallet_type)
        when 'trading'
          #TODO: Implement me
      end
    end
    return total, available
  end

  def reload
    # if Time.now - @reload[:startup] > 30
    #   #LogService.log_thing("#{@orderbook}")
    #   exit
    # end
    if @reload[:configuration].nil? || @conf.nil? || (Time.now - @reload[:configuration]) >= @conf['configuration']
      @conf = Config.conf
      @prod = @conf['testing'].to_i > 0 ? false : true
      @reload[:configuration] = Time.now
    end
    if @reload[:fees].nil? || (Time.now - @reload[:fees]) >= @conf['fees']
      LogService.log_thing "Loading up fees..."
      @fees = $client.account_info[0]
      @fees['maker_fees'] = @fees['maker_fees'].to_d / 100
      @fees['taker_fees'] = @fees['taker_fees'].to_d / 100
      LogService.log_thing "Maker fees are #{@fees['maker_fees']}, taker fees are #{@fees['taker_fees']}"
      @reload[:fees] = Time.now
    end
    if @reload[:pairs].nil? || (Time.now - @reload[:pairs]) >= @conf['pairs']
      LogService.log_thing "Loading up pairs..."
      @pairs = $client.symbols_details
      @pairs_list = @pairs.map { |p| p['pair'].to_s.downcase }
      @currencies = @pairs_list.map { |p| [p[0..2], p[3..5]] }.flatten.uniq
      get_ring(3)
      LogService.log_thing "List of pairs is #{@pairs_list}"
      LogService.log_thing "List of circles is #{@ring_pairs}"
      @reload[:pairs] = Time.now
    end
  end

  def reload_max_ring_balance(currency = nil)
    if @reload[:ring_balances].nil? || (Time.now - @reload[:ring_balances]) >= @conf['ring_balances']
      LogService.log_thing "Loading up maimum ring balance"
      @ring_pairs.each do |ring|
        next if currency && !ring.select { |r| r.include?(currency) }.first
        @available_ring_balance[ring.to_s.to_sym] = get_max_ring_tradable_balance((@conf['arbitrage_on_margin'] && @conf['arbitrage_on_margin'] != 1) ? 'exchange' : 'trading', ring)
      end
      LogService.log_thing("@available_ring_balance #{@available_ring_balance}")
      @reload[:ring_balances] = Time.now
    end
  end

end