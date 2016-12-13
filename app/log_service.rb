class LogService

  def self.log_thing(info)
    puts info
    $logger.info(info)
  end

  def self.error_log(e, src)
    puts "In #{src}"
    puts e
    $logger_error.error("ERROR #{Time.now.utc.to_s} #{src}")
    $logger_error.error(e)
    $logger_error.error(e.backtrace.join("\n")) if e.backtrace
  end

end
