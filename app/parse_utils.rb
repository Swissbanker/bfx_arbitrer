class ParseUtils

  def self.parse_ws_ticker(tick)
    tick.map! { |a| a.to_d }
    {'mid' => (tick[1] + tick[3]) / 2, # [price] (bid + ask) / 2
     'bid' => tick[1], # [price] Innermost bid.
     'ask' => tick[3], # [price] Innermost ask.
     'last_price' => tick[6], # [price] The price at which the last order executed.
     'timestamp' => Time.now.to_i}
  end

  def self.parse_ws_book(orderbook, msg)
    level = {}
    orderbook['ask'] = Hamster::SortedSet.new() { |a| a['price'] } unless orderbook['ask']
    orderbook['bid'] = Hamster::SortedSet.new() { |a| -a['price'] } unless orderbook['bid']
    if msg[1].is_a?(Array)
      msg[1].each do |n_msg|
        orderbook, _ = parse_ws_book(orderbook, n_msg)
      end
    else
      cpt = msg.count - 3
      amount = msg[2 + cpt].to_d
      orderbook['bid'] = orderbook['bid'].select { |x| x['price'] != msg[0 + cpt] }
      orderbook['ask'] = orderbook['ask'].select { |x| x['price'] != msg[0 + cpt] }
      side = amount > 0 ? 'bid' : 'ask'
      level = {
          'price' => msg[0 + cpt].to_d,
          'count' => msg[1 + cpt].to_i,
          'amount' => amount
      }
      orderbook[side] = orderbook[side].add(level)
    end
    return orderbook, level
  end
end