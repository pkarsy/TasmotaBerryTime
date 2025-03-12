# Panagiotis Karagiannis
# https://github.com/pkarsy/TasmotaBerryTime/

# We encapsulate all functionality inside this block 
# to avoid pulluting the global namespace
do
  import strict

  # Useful when developing this driver. Allows to clean the runtime
  # objects and reloading the code
  if global.ds3231 != nil
    global.ds3231.stop()
    global.ds3231 = nil
    tasmota.gc()
  end

  var MSG='DS3231: '
  var RULE='Time#Set'
  var RULEID='ds3231'

  # helper functions for the communication with DS3231.
  # Returns a string with len=2. For this specific case
  # the string is more handy than an integer.
  def bcd2int(x)
    return str(x/16) + str(x%16)
  end

  # returns a BCD encoded integer
  def int2bcd(x)
    return (x/10)*16+(x%10)
  end
  
  # converts the system time to the format DS3231 accepts but does not write
  # anything to the DS3231 registers
  def system2bcd()
    var t = tasmota.rtc_utc()
    # now t is epoch time (integer seconds from 1/1/1970)
    t = tasmota.time_dump(t)
    # now t is something like
    # "{'min': 58, 'weekday': 6, 'sec': 0, 'month': 5, 'year': 2024,
    # 'day': 18, 'epoch': 1716058680, 'hour': 18}"
    t=[ t['sec'], t['min'], t['hour'], t['weekday'], t['day'], t['month'], t['year']%100 ]
    # Now t is in the order DS3231 needs but not in BCD yet
    # We create a buffer with 7 bytes
    var buf = bytes(7)
    for x:t
      buf.add( int2bcd(x),1 )
    end
    # now b contains all register values in the correct order and in BCD
    return buf
  end
  # end of helper functions

  # This class implements all machinery to store and read the DS3231
  class DS3231
    var w # The wire object containing the DS3231 connection
    var addr

    def init()
      self.addr = 0x68
      if global.('DS3231_ADDR')!=nil
        self.addr = global.DS3231_ADDR
      end
      self.w = tasmota.wire_scan(self.addr)
      if self.w == nil
        import string
        print( MSG+'The chip is not detected at the I2C address 0x' + string.hex(self.addr))
      else
        print( MSG+'found DS3231 chip' )
        # TODO dedicated UTC function
        if tasmota.rtc_utc()<1716100000 # The system time is certainly wrong
          self.rtc2system()
        else # The system time may be wrong/correct but we cant be sure
          print('System time seems to be set, call rtc2system() or system2rtc() to force an update')
        end
        # Every time the system gets NTP time the RTC is updated (about every hour)
        tasmota.add_rule(RULE, /->self.system2rtc(), RULEID)
      end
    end

    # Updates the tasmota system time, using DS3231 as time source 
    def rtc2system()
      if self.w == nil
        print(MSG+'Cannot set the system time, RTC chip is not present')
        return
      end
      # We read 7 registers from DS3231 with addresses 0-6
      var b=self.w.read_bytes(self.addr, 0, 7)
      var t=[]
      for i : 0..6
        t.push(bcd2int(b[i]))
      end
      t.pop(3) # we remove the "week" field, not needed to build the epoch time
      t.reverse()
      t[0]='20' + t[0] # The year from 24(DS3231) -> 2024(string value)
      # Todo check unparsed and epoch > 2023
      t = tasmota.strptime(t.concat(' ') ,"%Y %m %d %H %M %S")['epoch']
      var ctime = 1716000000 # about the time this script is created or updated
      if t<ctime t=ctime end # we set the time with an outdated but at least non zero value
      # I found that the rule time#set only works when the time is set initially
      # even whith an oudated value
      tasmota.cmd('time ' .. t+1, true) # +1 to compensate the delay when fetching the time
      if t>ctime
        print(MSG+'Updated the system time from RTC chip')
      else
        print(MSG+'The RTC time is wrong, connect at least once to the internet')
      end
      tasmota.cmd('time 0', true) # this is to reenable NTP time updates
    end

    def system2rtc()
      if self.w == nil
        print(MSG + 'Cannot set the RTC time, the chip in not present')
        return
      end
      var buf = system2bcd() # Now buf contains the suitable register values
      # we write to the DS3231 registers
      self.w.write_bytes(self.addr, 0, buf)
      print(MSG + 'Using NTP to update the DS3231 time')
    end

    def stop()
      tasmota.remove_rule(RULE, RULEID)
    end

    def active()
      if self.w == nil return false
      else return true end
    end

    def deinit()
      print(self, 'deinit()')
    end

  end # class DS3231
  # We need just one instance, and we make it global
  global.ds3231 = DS3231()
end
